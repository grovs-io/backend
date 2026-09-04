# frozen_string_literal: true

require "test_helper"

class BatchEventProcessorPrimarySpillTest < ActiveSupport::TestCase
  include ClickhouseTestHelper

  fixtures :instances, :projects, :devices, :visitors, :links, :domains, :redirect_configs, :events,
           :visitor_daily_statistics, :link_daily_statistics

  setup do
    @job = BatchEventProcessorJob.new
    @job.jid = "primary-test-jid-#{SecureRandom.hex(4)}"
    @project = projects(:one)
    @device = devices(:ios_device)
    @link = links(:basic_link)

    REDIS.with { |conn| conn.del(BatchEventProcessorJob::REDIS_KEY) }

    @original_ch_enabled = Rails.application.config.clickhouse_write_enabled
    Rails.application.config.clickhouse_write_enabled = true
  end

  teardown do
    Rails.application.config.clickhouse_write_enabled = @original_ch_enabled
    REDIS.with do |conn|
      conn.del(BatchEventProcessorJob::REDIS_KEY)
      conn.del("events:processing:#{@job.jid}")
      conn.del("events:heartbeat:#{@job.jid}")
      keys = conn.keys("#{BatchEventProcessorJob::CH_BATCH_DONE_PREFIX}:*")
      conn.del(*keys) if keys.any?
    end
  end

  def open_event_json(created_at: 1.hour.from_now)
    {
      type: Grovs::Events::OPEN, project_id: @project.id, device_id: @device.id,
      data: nil, link_id: @link.id, engagement_time: nil, created_at: created_at.iso8601
    }.to_json
  end

  test "primary mode with CH up: no PG events, CH row written, stats written, no spill" do
    skip_unless_clickhouse!

    with_clickhouse_primary do
      assert_no_difference "Event.count" do
        assert_difference "LinkDailyStatistic.count", 1 do
          @job.send(:process_batch, [open_event_json])
        end
      end
    end

    assert_equal 1, ch_event_count(@project.id, event_type: Grovs::Events::OPEN)
    assert_equal 0, ClickhouseEventSpill.count
  end

  test "primary mode with CH down: events spill to PG, stats still written" do
    with_clickhouse_primary do
      ClickhouseWriteService.stub(:raw_insert, proc { raise "ch down" }) do
        assert_no_difference "Event.count" do
          assert_difference ["ClickhouseEventSpill.count", "LinkDailyStatistic.count"], 1 do
            @job.send(:process_batch, [open_event_json])
          end
        end
      end
    end

    spill = ClickhouseEventSpill.last
    assert spill.event_id.present?
    assert_equal @project.id, spill.project_id
    assert_equal Grovs::Events::OPEN, spill.ch_row["event_type"]
    assert_kind_of String, spill.ch_row["created_at"]
    assert_equal 0, spill.attempts
  end

  test "primary mode: spilled rows carry the frozen event_id from the payload" do
    payload = JSON.parse(open_event_json).merge(
      "event_id" => "frozen-primary-id", "sdk_generated" => false
    ).to_json

    with_clickhouse_primary do
      ClickhouseWriteService.stub(:raw_insert, proc { raise "ch down" }) do
        @job.send(:process_batch, [payload])
      end
    end

    assert ClickhouseEventSpill.exists?(event_id: "frozen-primary-id")
  end

  test "primary mode: replaying the same batch collapses to one CH event (crash replay safety)" do
    skip_unless_clickhouse!
    payload = JSON.parse(open_event_json).merge("event_id" => "replay-safe-id", "sdk_generated" => false).to_json

    with_clickhouse_primary do
      @job.send(:process_batch, [payload])
      @job.send(:process_batch, [payload])
    end

    assert_equal 1, ch_event_count(@project.id, event_type: Grovs::Events::OPEN)
    assert_equal 0, ClickhouseEventSpill.count
  end

  test "primary mode: user profile upsert failure does not fail the batch" do
    with_clickhouse_primary do
      @job.stub(:upsert_user_profiles, proc { raise "profile boom" }) do
        ClickhouseWriteService.stub(:raw_insert, proc { raise "ch down" }) do
          assert_equal :success, @job.send(:process_batch, [open_event_json])
        end
      end
    end
    assert_equal 1, ClickhouseEventSpill.count
  end

  test "primary mode off: PG events written exactly as before, no spill" do
    Rails.application.config.clickhouse_write_enabled = false

    assert_difference "Event.count", 1 do
      @job.send(:process_batch, [open_event_json])
    end
    assert_equal 0, ClickhouseEventSpill.count
  end
end
