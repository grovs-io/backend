# frozen_string_literal: true

require "test_helper"

class LogEventJobPrimaryTest < ActiveSupport::TestCase
  include ClickhouseTestHelper

  fixtures :instances, :projects, :devices, :visitors, :links, :domains, :redirect_configs

  setup do
    @project = projects(:one)
    @device = devices(:ios_device)
    REDIS.with { |c| c.del(BatchEventProcessorJob::REDIS_KEY) }
  end

  teardown do
    REDIS.with { |c| c.del(BatchEventProcessorJob::REDIS_KEY) }
  end

  test "primary mode: re-enqueues into batch pipeline preserving created_at, writes no PG event" do
    original_ts = "2026-07-20T09:15:30.123Z"

    with_clickhouse_primary do
      assert_no_difference "Event.count" do
        LogEventJob.new.perform(Grovs::Events::OPEN, @project.id, @device.id, nil, nil, nil, original_ts, "", "", [])
      end
    end

    raw = REDIS.with { |c| c.rpop(BatchEventProcessorJob::REDIS_KEY) }
    assert raw.present?, "expected a payload in the batch pipeline"
    payload = JSON.parse(raw)
    assert_equal Grovs::Events::OPEN, payload["type"]
    assert_equal @project.id, payload["project_id"]
    assert_equal Time.parse(original_ts).iso8601(3), payload["created_at"]
    assert payload["event_id"].present?
  end

  test "primary mode: Redis re-enqueue failure falls to sync write, never back through Sidekiq" do
    lpush_raises = proc { |*| raise Redis::TimeoutError, "pool exhausted" }

    with_clickhouse_primary do
      REDIS.stub(:lpush, lpush_raises) do
        assert_difference "Event.count", 1 do
          LogEventJob.new.perform(Grovs::Events::OPEN, @project.id, @device.id, nil, nil, nil, nil, "", "", [])
        end
      end
    end
  end

  test "flag off: writes PG event synchronously as before" do
    assert_difference "Event.count", 1 do
      LogEventJob.new.perform(Grovs::Events::OPEN, @project.id, @device.id, nil, nil, nil, nil, "", "", [])
    end
    assert_equal 0, REDIS.with { |c| c.llen(BatchEventProcessorJob::REDIS_KEY) }
  end
end
