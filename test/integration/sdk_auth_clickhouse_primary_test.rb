# frozen_string_literal: true

require "test_helper"
require_relative "auth_test_helper"

class SdkAuthClickhousePrimaryTest < ActionDispatch::IntegrationTest
  include AuthTestHelper
  include ClickhouseTestHelper

  fixtures :instances, :projects, :applications, :ios_configurations,
           :android_configurations, :devices, :visitors, :domains, :redirect_configs

  setup do
    skip_unless_clickhouse!
    @project = projects(:one)
    @visitor = visitors(:ios_visitor)
    @device = @visitor.device
    @headers = sdk_headers_for(@project, @visitor, platform: "ios")
    @original_read_enabled = Rails.application.config.clickhouse_read_enabled
    @original_write_enabled = Rails.application.config.clickhouse_write_enabled
    Rails.application.config.clickhouse_read_enabled = true
    Rails.application.config.clickhouse_write_enabled = true
    Event.where(device_id: @device.id).delete_all
    DeviceLastSeen.where(device_id: @device.id).delete_all
    clear_event_redis_namespace
  end

  teardown do
    Rails.application.config.clickhouse_read_enabled = @original_read_enabled if defined?(@original_read_enabled)
    Rails.application.config.clickhouse_write_enabled = @original_write_enabled if defined?(@original_write_enabled)
    clear_event_redis_namespace
  end

  # Seeding CH directly would not catch the batch dropping the write or mismapping device_id.
  test "an ingested APP_OPEN reaches last_seen through the real batch pipeline, with no PG event row" do
    occurred_at = 2.minutes.ago
    payload = {
      type: Grovs::Events::APP_OPEN, project_id: @project.id, device_id: @device.id,
      data: nil, link_id: nil, engagement_time: nil, created_at: occurred_at.iso8601(3)
    }.to_json

    job = BatchEventProcessorJob.new
    job.jid = "sdk-auth-ch-#{SecureRandom.hex(4)}"
    REDIS.with { |conn| conn.lpush("events:processing:#{job.jid}", payload) }

    Clickhouse.stub(:primary?, true) do
      assert_no_difference "Event.count" do
        assert_equal :success, job.send(:process_batch, [payload])
      end

      assert_in_delta occurred_at.to_f, Time.zone.parse(fetch_last_seen).to_f, 1.0
    end
  end

  test "a stamped device is served from the table" do
    at = 20.minutes.ago
    DeviceLastSeen.stamp_batch!({ [@project.id, @device.id] => at })

    Clickhouse.stub(:primary?, true) do
      assert_in_delta at.to_f, Time.zone.parse(fetch_last_seen).to_f, 1.0
    end
  end

  test "the stamp wins over devices.updated_at even when the device was touched later" do
    stamped = 3.days.ago
    DeviceLastSeen.stamp_batch!({ [@project.id, @device.id] => stamped })
    set_device_timestamps(created_at: 10.days.ago, updated_at: 1.minute.ago)

    Clickhouse.stub(:primary?, true) do
      assert_in_delta stamped.to_f, Time.zone.parse(fetch_last_seen).to_f, 1.0
    end
  end

  test "an unstamped device with a visitor here answers from devices.updated_at" do
    touched = 2.hours.ago
    assert Visitor.exists?(project_id: @project.id, device_id: @device.id)
    set_device_timestamps(created_at: 10.days.ago, updated_at: touched)

    Clickhouse.stub(:primary?, true) do
      assert_in_delta touched.to_f, Time.zone.parse(fetch_last_seen).to_f, 1.0
    end
  end

  # Rails stamps both on create; a device untouched since then has never been seen again.
  test "a device never touched since creation answers null" do
    created = 5.minutes.ago
    set_device_timestamps(created_at: created, updated_at: created)

    Clickhouse.stub(:primary?, true) do
      assert_nil fetch_last_seen, "a fresh device must not read as a previous visit"
    end
  end

  # Creation and the follow-up data POST land milliseconds apart, so equality would be too strict.
  test "a sub-window gap between creation and touch still reads as never seen" do
    created = 5.minutes.ago
    set_device_timestamps(created_at: created, updated_at: created + 2.seconds)

    Clickhouse.stub(:primary?, true) do
      assert_nil fetch_last_seen
    end
  end

  test "a touch just past the window reads as seen" do
    created = 5.minutes.ago
    touched = created + Api::V1::Sdk::AuthController::DEVICE_FRESH_WINDOW + 5.seconds
    set_device_timestamps(created_at: created, updated_at: touched)

    Clickhouse.stub(:primary?, true) do
      assert_in_delta touched.to_f, Time.zone.parse(fetch_last_seen).to_f, 1.0
    end
  end

  # Same IDFV across a customer's test and production keys is one Device row with two Visitors.
  test "activity in another project does not answer through devices.updated_at" do
    other = Device.create!(user_agent: "CrossProject/1", ip: "10.0.0.9", remote_ip: "10.0.0.9",
                           platform: "ios", vendor: "cross-#{SecureRandom.hex(6)}")
    Visitor.create!(project: projects(:two), device: other, web_visitor: false)
    DeviceLastSeen.where(device_id: other.id).delete_all
    other.update_columns(created_at: 10.days.ago, updated_at: 2.hours.ago)

    Clickhouse.stub(:primary?, true) do
      assert_nil fetch_last_seen(vendor: other.vendor),
        "a device never seen in this project must not inherit another project's activity"
    end
  end

  test "another project's stamp does not leak into last_seen" do
    DeviceLastSeen.stamp_batch!({ [projects(:two).id, @device.id] => 1.minute.ago })
    created = 5.minutes.ago
    set_device_timestamps(created_at: created, updated_at: created)

    Clickhouse.stub(:primary?, true) do
      assert_nil fetch_last_seen
    end
  end

  test "the lookup issues no ClickHouse query at all" do
    DeviceLastSeen.stamp_batch!({ [@project.id, @device.id] => 20.minutes.ago })

    Clickhouse.stub(:primary?, true) do
      failing_ch { assert_not_nil fetch_last_seen }
    end
  end

  test "a ClickHouse outage cannot affect the unstamped answer either" do
    touched = 2.hours.ago
    set_device_timestamps(created_at: 10.days.ago, updated_at: touched)

    Clickhouse.stub(:primary?, true) do
      failing_ch { assert_in_delta touched.to_f, Time.zone.parse(fetch_last_seen).to_f, 1.0 }
    end
  end

  test "primary mode off reads the live Postgres events table, not the stamp" do
    DeviceLastSeen.stamp_batch!({ [@project.id, @device.id] => 1.minute.ago })
    event = Event.create!(project_id: @project.id, device_id: @device.id,
                          event: Grovs::Events::APP_OPEN, created_at: 2.hours.ago)

    Clickhouse.stub(:primary?, false) do
      assert_in_delta event.created_at.to_f, Time.zone.parse(fetch_last_seen).to_f, 1.0
    end
  end

  # find_by(vendor: nil) would otherwise match an arbitrary web visitor's device.
  test "a blank vendor answers null without looking up a device" do
    Device.stub(:redis_find_by, ->(*) { flunk("no lookup should happen for a blank vendor") }) do
      assert_nil fetch_last_seen(vendor: "")
    end
  end

  test "an unknown vendor answers null without raising" do
    get "#{SDK_PREFIX}/device_for_vendor_id",
      params: { vendor_id: "no-such-vendor-#{SecureRandom.hex(4)}" }, headers: @headers

    assert_response :ok
    assert_nil JSON.parse(response.body)["last_seen"]
  end

  private

  # update_columns skips the invalidation hook, so the controller would read a stale cached device.
  def set_device_timestamps(created_at:, updated_at:)
    @device.update_columns(created_at: created_at, updated_at: updated_at)
    keys = @device.cache_keys_to_clear
    REDIS.del(*keys) if keys.present?
  end

  # Fails inside the query itself, so the service's own rescue decides what the caller sees.
  def failing_ch(&block)
    Clickhouse.stub(:with, ->(*) { raise ClickHouse::Client::DatabaseError, "timeout" }, &block)
  end

  def clear_event_redis_namespace
    REDIS.with do |conn|
      cursor = "0"
      loop do
        cursor, keys = conn.scan(cursor, match: "events:*", count: 1000)
        conn.del(*keys) unless keys.empty?
        break if cursor == "0"
      end
    end
  end

  def fetch_last_seen(vendor: @device.vendor)
    get "#{SDK_PREFIX}/device_for_vendor_id",
      params: { vendor_id: vendor }, headers: @headers

    assert_response :ok
    JSON.parse(response.body)["last_seen"]
  end
end
