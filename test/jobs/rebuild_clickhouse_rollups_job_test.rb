# frozen_string_literal: true

require "test_helper"

class RebuildClickhouseRollupsJobTest < ActiveSupport::TestCase
  test "delegates to the rebuild service" do
    called = false
    ClickhouseRollupRebuildService.stub(:rebuild_all_dirty, ->(**) { called = true }) do
      RebuildClickhouseRollupsJob.new.perform
    end

    assert called
  end

  test "rescues and logs service errors so the schedule stays healthy" do
    ClickhouseRollupRebuildService.stub(:rebuild_all_dirty, ->(**) { raise "boom" }) do
      assert_nothing_raised { RebuildClickhouseRollupsJob.new.perform }
    end
  end

  test "emits a failure metric when the rebuild raises so a frozen rollup is alertable" do
    names = []
    Grovs::Metrics.stub(:increment, ->(name, **) { names << name }) do
      ClickhouseRollupRebuildService.stub(:rebuild_all_dirty, ->(**) { raise "boom" }) do
        RebuildClickhouseRollupsJob.new.perform
      end
    end

    assert_includes names, "clickhouse.rollup_rebuild.failed"
  end

  test "current_month scope no-ops when the fast lane is disabled" do
    range_called = false
    ClickhouseRollupRebuildService.stub(:fast_lane_enabled?, false) do
      ClickhouseRollupRebuildService.stub(:rebuild_partition_range, ->(*, **) { range_called = true }) do
        RebuildClickhouseRollupsJob.new.perform("current_month")
      end
    end

    assert_not range_called
  end

  test "current_month scope rebuilds only the current partition including acquisition" do
    captured = nil
    full_called = false
    ClickhouseRollupRebuildService.stub(:fast_lane_enabled?, true) do
      ClickhouseRollupRebuildService.stub(:rebuild_all_dirty, ->(**) { full_called = true }) do
        ClickhouseRollupRebuildService.stub(
          :rebuild_partition_range,
          ->(from, to, rollups:, strict:) { captured = [from, to, rollups, strict] }
        ) do
          RebuildClickhouseRollupsJob.new.perform("current_month")
        end
      end
    end

    expected_partition = Date.current.strftime("%Y%m")
    assert_equal expected_partition, captured[0]
    assert_equal expected_partition, captured[1]
    assert_equal ClickhouseRollupRebuildService::ROLLUPS.keys + [:acquisition], captured[2]
    assert captured[3], "fast lane must use strict mode so failures alert"
    assert_not full_called
  end

  test "current_month scope rescues service errors" do
    ClickhouseRollupRebuildService.stub(:fast_lane_enabled?, true) do
      ClickhouseRollupRebuildService.stub(:rebuild_partition_range, ->(*, **) { raise "boom" }) do
        assert_nothing_raised { RebuildClickhouseRollupsJob.new.perform("current_month") }
      end
    end
  end

  test "fast lane emits the failure metric when an underlying rollup fails" do
    names = []
    Grovs::Metrics.stub(:increment, ->(name, **) { names << name }) do
      Clickhouse.stub(:enabled?, true) do
        ClickhouseRollupRebuildService.stub(:fast_lane_enabled?, true) do
          ClickhouseRollupRebuildService.stub(:rebuild_partition, ->(*) { raise "boom" }) do
            ClickhouseRollupRebuildService.stub(:rebuild_acquisition, ->(*) { true }) do
              assert_nothing_raised { RebuildClickhouseRollupsJob.new.perform("current_month") }
            end
          end
        end
      end
    end

    assert_includes names, "clickhouse.rollup_rebuild.failed"
  end

  test "a successful fast lane stamps its liveness key" do
    REDIS.del(ClickhouseRollupLiveness.key(:fast))

    ClickhouseRollupRebuildService.stub(:fast_lane_enabled?, true) do
      ClickhouseRollupRebuildService.stub(:rebuild_partition_range, ->(*, **) { nil }) do
        RebuildClickhouseRollupsJob.new.perform("current_month")
      end
    end

    assert REDIS.get(ClickhouseRollupLiveness.key(:fast)).present?
  end

  test "a successful full lane stamps its liveness key" do
    REDIS.del(ClickhouseRollupLiveness.key(:full))

    stub_full_lane(failed: []) { RebuildClickhouseRollupsJob.new.perform }

    assert REDIS.get(ClickhouseRollupLiveness.key(:full)).present?
  end

  test "a full lane whose partitions all failed leaves the gate unstamped" do
    REDIS.del(ClickhouseRollupLiveness.key(:full))
    window = ClickhouseRollupRebuildService.watermark_partitions(2, Time.current)

    stub_full_lane(failed: window) { RebuildClickhouseRollupsJob.new.perform }

    assert_nil REDIS.get(ClickhouseRollupLiveness.key(:full))
  end

  test "a failed full lane leaves its liveness key unstamped" do
    REDIS.del(ClickhouseRollupLiveness.key(:full))

    ClickhouseRollupRebuildService.stub(:rebuild_all_dirty, ->(**) { raise "boom" }) do
      assert_nothing_raised { RebuildClickhouseRollupsJob.new.perform }
    end

    assert_nil REDIS.get(ClickhouseRollupLiveness.key(:full))
  end

  # Turning the fast lane off left NOTHING stamping liveness, so every rollup read 503'd.
  test "the full lane alone keeps analytics fresh when the fast lane is disabled" do
    ClickhouseRollupLiveness.clear!

    ClickhouseRollupRebuildService.stub(:fast_lane_enabled?, false) do
      assert_not ClickhouseRollupLiveness.fresh?, "no lane has run yet"

      stub_full_lane(failed: []) { RebuildClickhouseRollupsJob.new.perform }

      assert ClickhouseRollupLiveness.fresh?, "the full lane must satisfy the gate on its own"
    end
  end

  test "catchup scope delegates to rebuild_stale_dirty without running the full pass" do
    stale_called = false
    full_called = false
    ClickhouseRollupRebuildService.stub(:rebuild_stale_dirty, ->(**) { stale_called = true }) do
      ClickhouseRollupRebuildService.stub(:rebuild_all_dirty, ->(**) { full_called = true }) do
        RebuildClickhouseRollupsJob.new.perform("catchup")
      end
    end

    assert stale_called
    assert_not full_called
  end

  test "full scope skips when another full run holds the single-flight lock" do
    lock_key = "sidekiq:single_flight:rollup_full"
    REDIS.with { |c| c.set(lock_key, "held", nx: true, ex: 60) }
    called = false
    ClickhouseRollupRebuildService.stub(:rebuild_all_dirty, ->(**) { called = true }) do
      RebuildClickhouseRollupsJob.new.perform
    end

    assert_not called, "an overlapping full run must skip, not stack CH load"
  ensure
    REDIS.with { |c| c.del(lock_key) }
  end

  test "catchup scope skips when another catch-up run holds the single-flight lock" do
    lock_key = "sidekiq:single_flight:rollup_catchup"
    REDIS.with { |c| c.set(lock_key, "held", nx: true, ex: 60) }
    called = false
    ClickhouseRollupRebuildService.stub(:rebuild_stale_dirty, ->(**) { called = true }) do
      RebuildClickhouseRollupsJob.new.perform("catchup")
    end

    assert_not called, "an overlapping catch-up run must skip, not double the CH load"
  ensure
    REDIS.with { |c| c.del(lock_key) }
  end

  test "catchup scope rescues errors and emits the failure metric with the catchup lane" do
    metrics = []
    Grovs::Metrics.stub(:increment, ->(name, **kw) { metrics << [name, kw.dig(:tags, :lane)] }) do
      ClickhouseRollupRebuildService.stub(:rebuild_stale_dirty, ->(**) { raise "boom" }) do
        assert_nothing_raised { RebuildClickhouseRollupsJob.new.perform("catchup") }
      end
    end

    assert_includes metrics, ["clickhouse.rollup_rebuild.failed", "catchup"]
  end

  test "a failed fast lane leaves its liveness key unstamped" do
    REDIS.del(ClickhouseRollupLiveness.key(:fast))

    ClickhouseRollupRebuildService.stub(:fast_lane_enabled?, true) do
      ClickhouseRollupRebuildService.stub(:rebuild_partition_range, ->(*, **) { raise "boom" }) do
        RebuildClickhouseRollupsJob.new.perform("current_month")
      end
    end

    assert_nil REDIS.get(ClickhouseRollupLiveness.key(:fast))
  end

  private

  # Stubs below rebuild_all_dirty so its own failed-partition check decides the stamp.
  def stub_full_lane(failed:, &block)
    Clickhouse.stub(:enabled?, true) do
      ClickhouseRollupRebuildService.stub(:rebuild_partitions, ->(_partitions) { failed }, &block)
    end
  end
end
