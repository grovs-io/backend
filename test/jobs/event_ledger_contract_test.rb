# frozen_string_literal: true

require "test_helper"

class EventLedgerContractTest < ActiveSupport::TestCase
  include ClickhouseTestHelper

  fixtures :instances, :projects, :devices, :visitors, :links, :domains, :redirect_configs,
           :visitor_daily_statistics, :link_daily_statistics

  EXPECTED_STAT_EVENTS = Grovs::Events::MAPPING.keys.freeze
  CLICKHOUSE_ONLY_EVENTS = [Grovs::Events::SCREEN_VIEW, Grovs::Events::CUSTOM].freeze

  setup do
    skip_unless_clickhouse!

    @project = projects(:one)
    @device = devices(:ios_device)
    @visitor = visitors(:ios_visitor)
    @link = links(:basic_link)
    @job = BatchEventProcessorJob.new
    @job.jid = "event-ledger-contract-#{SecureRandom.hex(4)}"

    @original_ch_enabled = Rails.application.config.clickhouse_write_enabled
    Rails.application.config.clickhouse_write_enabled = true

    clear_batch_redis_state
    reset_stats!
  end

  teardown do
    Rails.application.config.clickhouse_write_enabled = @original_ch_enabled if defined?(@original_ch_enabled)
    clear_batch_redis_state if defined?(@project)
  end

  test "every event type has a consistent Postgres to ClickHouse ledger row and expected stat behavior" do
    raw_payloads = Grovs::Events::ALL.each_with_index.map do |event_type, index|
      payload_for(event_type, index)
    end

    assert_difference "Event.count", Grovs::Events::ALL.size do
      assert_equal :success, @job.send(:process_batch, raw_payloads.map(&:to_json))
    end

    pg_events = Event.where(project_id: @project.id).where(event: Grovs::Events::ALL)
                     .where("event_name LIKE ?", "ledger_%")
                     .order(:event, :created_at)
    assert_equal Grovs::Events::ALL.size, pg_events.size

    ch_events = ch_select_events(@project.id, columns: %w[
      event_type event_name session_id device_id visitor_id link_id engagement_time
      properties tags platform app_version build path tracking_source tracking_campaign
      sdk_identifier
    ])
    ledger_ch_events = ch_events.select { |row| row["event_name"].to_s.start_with?("ledger_") }
    assert_equal Grovs::Events::ALL.size, ledger_ch_events.size

    Grovs::Events::ALL.each do |event_type|
      payload = raw_payloads.find { |row| row[:type] == event_type }
      pg_event = pg_events.find { |event| event.event == event_type }
      ch_event = ledger_ch_events.find { |row| row["event_type"] == event_type }

      assert pg_event, "missing PG event for #{event_type}"
      assert ch_event, "missing ClickHouse event for #{event_type}"

      assert_equal payload[:event_name], pg_event.event_name
      assert_equal payload[:event_name], ch_event["event_name"]
      assert_equal payload[:session_id], pg_event.session_id
      assert_equal payload[:session_id], ch_event["session_id"]
      assert_equal payload[:device_id], pg_event.device_id
      assert_equal payload[:device_id], ch_event["device_id"]
      assert_equal @visitor.id, ch_event["visitor_id"]
      assert_equal payload[:link_id], pg_event.link_id
      assert_equal payload[:link_id] || 0, ch_event["link_id"]
      assert_equal payload[:data], pg_event.data
      assert_equal payload[:data] || {}, ch_event["properties"]
      assert_equal payload[:tags], pg_event.tags
      assert_equal payload[:tags], ch_event["tags"]
      assert_equal expected_engagement_time(event_type), pg_event.engagement_time.to_i
      assert_equal expected_engagement_time(event_type), ch_event["engagement_time"]
      assert_equal @device.platform, ch_event["platform"]
      assert_equal @device.app_version, ch_event["app_version"]
      assert_equal @device.build, ch_event["build"]
      assert_equal @link.path, ch_event["path"]
      assert_equal @link.tracking_source, ch_event["tracking_source"]
      assert_equal @link.tracking_campaign, ch_event["tracking_campaign"]
      assert_equal @visitor.sdk_identifier, ch_event["sdk_identifier"]
    end

    assert_stat_events_recorded_for(EXPECTED_STAT_EVENTS)
    assert_no_stats_for(CLICKHOUSE_ONLY_EVENTS)
  end

  test "install referral creates a separate user_referred ledger row in Postgres and ClickHouse" do
    referrer = visitors(:android_visitor)
    @link.update_column(:visitor_id, referrer.id)
    reset_stats!

    payload = payload_for(Grovs::Events::INSTALL, 0).merge(event_name: "ledger_install_referral")

    assert_difference "Event.count", 2 do
      assert_equal :success, @job.send(:process_batch, [payload.to_json])
    end

    occurred_at = Time.zone.parse(payload[:created_at])
    pg_events = Event.where(project_id: @project.id, created_at: occurred_at)
                     .where(event: [Grovs::Events::INSTALL, Grovs::Events::USER_REFERRED])
                     .order(:id)
                     .to_a
    assert_equal [Grovs::Events::INSTALL, Grovs::Events::USER_REFERRED], pg_events.map(&:event)

    ch_events = ch_select_events(@project.id, columns: %w[event_type device_id visitor_id link_id event_name])
    install_row = ch_events.find { |row| row["event_type"] == Grovs::Events::INSTALL }
    referred_row = ch_events.find { |row| row["event_type"] == Grovs::Events::USER_REFERRED }

    assert_equal @device.id, install_row["device_id"]
    assert_equal @visitor.id, install_row["visitor_id"]
    assert_equal @link.id, install_row["link_id"]
    assert_equal referrer.device_id, referred_row["device_id"]
    assert_equal referrer.id, referred_row["visitor_id"]
    assert_equal 0, referred_row["link_id"]
    assert_equal "", referred_row["event_name"]

    @visitor.reload
    assert_equal referrer.id, @visitor.inviter_id
    assert_equal 1, visitor_stat_value(Grovs::Events::INSTALL, visitor: @visitor)
    assert_equal 1, visitor_stat_value(Grovs::Events::USER_REFERRED, visitor: referrer)
  end

  test "with PG shadow writes off the pipeline still lands in ClickHouse and writes no PG stats" do
    payloads = [Grovs::Events::VIEW, Grovs::Events::OPEN].each_with_index.map do |event_type, index|
      payload_for(event_type, index).to_json
    end

    ENV["PG_SHADOW_WRITES"] = "false"
    begin
      assert_no_difference ["VisitorDailyStatistic.count", "LinkDailyStatistic.count"] do
        assert_equal :success, @job.send(:process_batch, payloads)
      end
    ensure
      ENV.delete("PG_SHADOW_WRITES")
    end

    ch_events = ch_select_events(@project.id, columns: %w[event_type event_name])
    landed = ch_events.select { |row| row["event_name"].to_s.start_with?("ledger_") }
    assert_equal [Grovs::Events::OPEN, Grovs::Events::VIEW], landed.map { |row| row["event_type"] }.sort
  end

  private

  def payload_for(event_type, index)
    {
      type: event_type,
      project_id: @project.id,
      device_id: @device.id,
      data: { "event_type" => event_type, "ordinal" => index },
      link_id: @link.id,
      engagement_time: event_type == Grovs::Events::TIME_SPENT ? 12_345 : nil,
      created_at: (Time.zone.parse("2026-06-23 10:00:00 UTC") + index.minutes).iso8601(3),
      event_name: "ledger_#{event_type}",
      session_id: "ledger_session_#{index}",
      tags: ["ledger", event_type]
    }
  end

  def expected_engagement_time(event_type)
    event_type == Grovs::Events::TIME_SPENT ? 12_345 : 0
  end

  def assert_stat_events_recorded_for(event_types)
    event_types.each do |event_type|
      assert_equal expected_stat_value(event_type), visitor_stat_value(event_type),
        "visitor stat mismatch for #{event_type}"
      assert_equal expected_stat_value(event_type), link_stat_value(event_type),
        "link stat mismatch for #{event_type}"
    end
  end

  def assert_no_stats_for(event_types)
    event_types.each do |event_type|
      assert_equal 0, visitor_stat_value(event_type), "unexpected visitor stat for #{event_type}"
      assert_equal 0, link_stat_value(event_type), "unexpected link stat for #{event_type}"
    end
  end

  def expected_stat_value(event_type)
    event_type == Grovs::Events::TIME_SPENT ? 12_345 : 1
  end

  def visitor_stat_value(event_type, visitor: @visitor)
    metric = Grovs::Events::MAPPING[event_type]
    return 0 unless metric

    VisitorDailyStatistic.where(
      project_id: @project.id,
      visitor_id: visitor.id,
      event_date: Date.new(2026, 6, 23)
    ).sum(metric)
  end

  def link_stat_value(event_type)
    metric = Grovs::Events::MAPPING[event_type]
    return 0 unless metric

    LinkDailyStatistic.where(
      project_id: @project.id,
      link_id: @link.id,
      event_date: Date.new(2026, 6, 23)
    ).sum(metric)
  end

  def reset_stats!
    VisitorDailyStatistic.where(project_id: @project.id).delete_all
    LinkDailyStatistic.where(project_id: @project.id).delete_all
    @visitor.update_column(:inviter_id, nil)
  end

  def clear_batch_redis_state
    REDIS.with do |conn|
      conn.del(BatchEventProcessorJob::REDIS_KEY)
      conn.del("events:processing:#{@job.jid}") if @job
      conn.del("events:heartbeat:#{@job.jid}") if @job
      conn.del("events:dedup:#{@project.id}:#{@device.id}:view") if @project && @device
      keys = conn.keys("#{BatchEventProcessorJob::CH_BATCH_DONE_PREFIX}:*")
      conn.del(*keys) if keys.any?
    end
  end
end
