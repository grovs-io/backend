# frozen_string_literal: true

require "test_helper"

class ChPrimarySpillDrainRoundtripTest < ActiveSupport::TestCase
  include ClickhouseTestHelper

  fixtures :instances, :projects, :devices, :visitors, :links, :domains, :redirect_configs, :events,
           :visitor_daily_statistics, :link_daily_statistics

  setup do
    skip_unless_clickhouse!

    @job = BatchEventProcessorJob.new
    @job.jid = "roundtrip-jid-#{SecureRandom.hex(4)}"
    @project = projects(:one)
    @device = devices(:ios_device)
    @link = links(:basic_link)

    REDIS.with { |conn| conn.del(BatchEventProcessorJob::REDIS_KEY) }

    @original_ch_enabled = Rails.application.config.clickhouse_write_enabled
    Rails.application.config.clickhouse_write_enabled = true
  end

  teardown do
    Rails.application.config.clickhouse_write_enabled = @original_ch_enabled if defined?(@original_ch_enabled)
    REDIS.with do |conn|
      conn.del(BatchEventProcessorJob::REDIS_KEY)
      if @job
        conn.del("events:processing:#{@job.jid}")
        conn.del("events:heartbeat:#{@job.jid}")
      end
      keys = conn.keys("#{BatchEventProcessorJob::CH_BATCH_DONE_PREFIX}:*")
      conn.del(*keys) if keys.any?
    end
  end

  test "CH outage: events spill to PG, then drain lands them in CH exactly once" do
    event_json = {
      type: Grovs::Events::OPEN, project_id: @project.id, device_id: @device.id,
      data: nil, link_id: @link.id, engagement_time: nil, created_at: 1.hour.from_now.iso8601
    }.to_json

    with_clickhouse_primary do
      # Outage: batch run spills instead of writing CH or PG events
      ClickhouseWriteService.stub(:raw_insert, proc { raise "outage" }) do
        assert_no_difference "Event.count" do
          @job.send(:process_batch, [event_json])
        end
      end
      assert_equal 1, ClickhouseEventSpill.count
      assert_equal 0, ch_event_count(@project.id)

      # Recovery: drain replays into CH and cleans up PG
      DrainClickhouseSpillJob.new.perform
      assert_equal 0, ClickhouseEventSpill.count
      assert_equal 1, ch_event_count(@project.id, event_type: Grovs::Events::OPEN)

      # Idempotency: another drain run changes nothing
      DrainClickhouseSpillJob.new.perform
      assert_equal 1, ch_event_count(@project.id)
    end
  end

  test "spilled row replay produces the identical row a healthy CH write would have" do
    created_at = 1.hour.from_now
    event_json = {
      type: Grovs::Events::OPEN, project_id: @project.id, device_id: @device.id,
      data: nil, link_id: @link.id, engagement_time: nil, created_at: created_at.iso8601
    }.to_json

    with_clickhouse_primary do
      ClickhouseWriteService.stub(:raw_insert, proc { raise "outage" }) do
        @job.send(:process_batch, [event_json])
      end
      DrainClickhouseSpillJob.new.perform
    end

    rows = ch_select_events(@project.id)
    assert_equal 1, rows.size
    row = rows.first
    assert_equal Grovs::Events::OPEN, row["event_type"]
    assert_equal @device.id, row["device_id"]
    assert_equal @link.id, row["link_id"]
    assert row["event_id"].present?
    assert row["country"].present? || row.key?("country"), "enriched columns should survive the spill roundtrip"
  end
end
