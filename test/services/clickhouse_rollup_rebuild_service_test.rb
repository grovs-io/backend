# frozen_string_literal: true

require "test_helper"

# CH-free control-flow tests: dirty-partition tracking and watermark selection.
class ClickhouseRollupRebuildServiceTest < ActiveSupport::TestCase
  setup do
    REDIS.with { |c| c.del(ClickhouseRollupRebuildService.dirty_key) }
  end

  teardown do
    REDIS.with { |c| c.del(ClickhouseRollupRebuildService.dirty_key) }
  end

  test "mark_dirty records the YYYYMM partition of the event date" do
    ClickhouseRollupRebuildService.mark_dirty(Date.new(2026, 6, 15))
    ClickhouseRollupRebuildService.mark_dirty(Date.new(2026, 5, 2))

    assert_equal %w[202605 202606], ClickhouseRollupRebuildService.dirty_partitions.sort
  end

  test "mark_dirty dedups repeated marks for the same partition" do
    3.times { ClickhouseRollupRebuildService.mark_dirty(Date.new(2026, 6, 1)) }

    assert_equal %w[202606], ClickhouseRollupRebuildService.dirty_partitions
  end

  test "rebuild_all_dirty rebuilds only the watermark window and defers older dirty partitions" do
    travel_to Time.utc(2026, 6, 26) do
      ClickhouseRollupRebuildService.mark_dirty(Date.new(2025, 7, 5))
      ClickhouseRollupRebuildService.mark_dirty(Date.new(2026, 5, 3))
      seen = []

      Clickhouse.stub(:enabled?, true) do
        ClickhouseRollupRebuildService.stub(:rebuild_partition, ->(_rollup, part) { seen << part }) do
          ClickhouseRollupRebuildService.stub(:rebuild_acquisition, ->(part) { seen << part }) do
            ClickhouseRollupRebuildService.rebuild_all_dirty(watermark_months: 2)
          end
        end
      end

      assert_equal %w[202604 202605 202606], seen.uniq.sort
      assert_equal %w[202507], ClickhouseRollupRebuildService.dirty_partitions
    end
  end

  test "rebuild_stale_dirty rebuilds only dirty partitions outside the watermark window and clears them" do
    travel_to Time.utc(2026, 6, 26) do
      ClickhouseRollupRebuildService.mark_dirty(Date.new(2025, 7, 5))
      ClickhouseRollupRebuildService.mark_dirty(Date.new(2026, 6, 3))
      seen = []

      Clickhouse.stub(:enabled?, true) do
        ClickhouseRollupRebuildService.stub(:rebuild_partition, ->(_rollup, part) { seen << part }) do
          ClickhouseRollupRebuildService.stub(:rebuild_acquisition, ->(part) { seen << part }) do
            ClickhouseRollupRebuildService.rebuild_stale_dirty(watermark_months: 2)
          end
        end
      end

      assert_equal %w[202507], seen.uniq
      assert_equal %w[202606], ClickhouseRollupRebuildService.dirty_partitions
    end
  end

  test "rebuild_stale_dirty is a no-op when every dirty partition is inside the window" do
    travel_to Time.utc(2026, 6, 26) do
      ClickhouseRollupRebuildService.mark_dirty(Date.new(2026, 6, 3))
      seen = []

      Clickhouse.stub(:enabled?, true) do
        ClickhouseRollupRebuildService.stub(:rebuild_partition, ->(_rollup, part) { seen << part }) do
          ClickhouseRollupRebuildService.stub(:rebuild_acquisition, ->(part) { seen << part }) do
            ClickhouseRollupRebuildService.rebuild_stale_dirty(watermark_months: 2)
          end
        end
      end

      assert_empty seen
      assert_equal %w[202606], ClickhouseRollupRebuildService.dirty_partitions
    end
  end

  test "rebuild_stale_dirty clears rebuilt partitions and keeps only the failed one dirty" do
    travel_to Time.utc(2026, 6, 26) do
      ClickhouseRollupRebuildService.mark_dirty(Date.new(2025, 1, 5))
      ClickhouseRollupRebuildService.mark_dirty(Date.new(2025, 3, 5))
      metrics = []

      Grovs::Metrics.stub(:increment, ->(name, **kw) { metrics << [name, kw.dig(:tags, :lane)] }) do
        Clickhouse.stub(:enabled?, true) do
          ClickhouseRollupRebuildService.stub(:rebuild_partition, lambda { |_rollup, part|
            raise "boom" if part == "202501"

            true
          }) do
            ClickhouseRollupRebuildService.stub(:rebuild_acquisition, ->(*) { true }) do
              ClickhouseRollupRebuildService.rebuild_stale_dirty(watermark_months: 2)
            end
          end
        end
      end

      assert_equal %w[202501], ClickhouseRollupRebuildService.dirty_partitions
      assert_includes metrics, ["clickhouse.rollup_rebuild.failed", "catchup"]
    end
  end

  test "rebuild_all_dirty clears rebuilt in-window dirty marks even when another window month fails" do
    travel_to Time.utc(2026, 6, 26) do
      ClickhouseRollupRebuildService.mark_dirty(Date.new(2026, 5, 3))
      metrics = []

      Grovs::Metrics.stub(:increment, ->(name, **kw) { metrics << [name, kw.dig(:tags, :lane)] }) do
        Clickhouse.stub(:enabled?, true) do
          ClickhouseRollupRebuildService.stub(:rebuild_partition, lambda { |_rollup, part|
            raise "boom" if part == "202604"

            true
          }) do
            ClickhouseRollupRebuildService.stub(:rebuild_acquisition, ->(*) { true }) do
              ClickhouseRollupRebuildService.rebuild_all_dirty(watermark_months: 2)
            end
          end
        end
      end

      assert_empty ClickhouseRollupRebuildService.dirty_partitions
      assert_includes metrics, ["clickhouse.rollup_rebuild.failed", "full"]
    end
  end

  test "a dirty mark added while a stale partition rebuilds survives the pass" do
    travel_to Time.utc(2026, 6, 26) do
      ClickhouseRollupRebuildService.mark_dirty(Date.new(2025, 1, 5))

      Clickhouse.stub(:enabled?, true) do
        ClickhouseRollupRebuildService.stub(:rebuild_partition, lambda { |*|
          # A visitor merge folding into this month mid-rebuild re-marks it.
          ClickhouseRollupRebuildService.mark_dirty(Date.new(2025, 1, 20))
          true
        }) do
          ClickhouseRollupRebuildService.stub(:rebuild_acquisition, ->(*) { true }) do
            ClickhouseRollupRebuildService.rebuild_stale_dirty(watermark_months: 2)
          end
        end
      end

      assert_equal %w[202501], ClickhouseRollupRebuildService.dirty_partitions,
                   "a mark added mid-rebuild must not be erased by the pass"
    end
  end

  test "rebuild_stale_dirty stops at the deadline and leaves remaining partitions dirty" do
    travel_to Time.utc(2026, 6, 26) do
      ClickhouseRollupRebuildService.mark_dirty(Date.new(2025, 1, 5))
      ClickhouseRollupRebuildService.mark_dirty(Date.new(2025, 3, 5))
      seen = []

      Clickhouse.stub(:enabled?, true) do
        ClickhouseRollupRebuildService.stub(:rebuild_partition, ->(_rollup, part) { seen << part }) do
          ClickhouseRollupRebuildService.stub(:rebuild_acquisition, ->(*) { true }) do
            ClickhouseRollupRebuildService.rebuild_stale_dirty(watermark_months: 2, deadline: Time.current)
          end
        end
      end

      assert_empty seen
      assert_equal %w[202501 202503], ClickhouseRollupRebuildService.dirty_partitions.sort
    end
  end

  test "a lock-skipped stale partition stays dirty and fires the catchup metric" do
    travel_to Time.utc(2026, 6, 26) do
      ClickhouseRollupRebuildService.mark_dirty(Date.new(2025, 1, 5))
      metrics = []

      Grovs::Metrics.stub(:increment, ->(name, **kw) { metrics << [name, kw.dig(:tags, :lane)] }) do
        Clickhouse.stub(:enabled?, true) do
          ClickhouseRollupRebuildService.stub(:rebuild_partition, ->(*) { false }) do
            ClickhouseRollupRebuildService.stub(:rebuild_acquisition, ->(*) { true }) do
              ClickhouseRollupRebuildService.rebuild_stale_dirty(watermark_months: 2)
            end
          end
        end
      end

      assert_equal %w[202501], ClickhouseRollupRebuildService.dirty_partitions,
                   "a lock skip is not a rebuild — clearing would drop the partition for good"
      assert_includes metrics, ["clickhouse.rollup_rebuild.failed", "catchup"]
    end
  end

  test "a successful rebuild_stale_dirty never stamps rollup liveness" do
    ClickhouseRollupLiveness.clear!
    travel_to Time.utc(2026, 6, 26) do
      ClickhouseRollupRebuildService.mark_dirty(Date.new(2025, 1, 5))

      Clickhouse.stub(:enabled?, true) do
        ClickhouseRollupRebuildService.stub(:rebuild_partition, ->(*) { true }) do
          ClickhouseRollupRebuildService.stub(:rebuild_acquisition, ->(*) { true }) do
            ClickhouseRollupRebuildService.rebuild_stale_dirty(watermark_months: 2)
          end
        end
      end

      # Stamping here would let a dead full lane serve frozen rollups under primary mode.
      assert_not ClickhouseRollupLiveness.fresh?
    end
  ensure
    ClickhouseRollupLiveness.clear!
  end

  test "rebuild_stale_dirty keeps partitions dirty and emits the catchup failure metric when a rebuild fails" do
    travel_to Time.utc(2026, 6, 26) do
      ClickhouseRollupRebuildService.mark_dirty(Date.new(2025, 7, 5))
      metrics = []

      Grovs::Metrics.stub(:increment, ->(name, **kw) { metrics << [name, kw.dig(:tags, :lane)] }) do
        Clickhouse.stub(:enabled?, true) do
          ClickhouseRollupRebuildService.stub(:rebuild_partition, ->(*) { raise "boom" }) do
            ClickhouseRollupRebuildService.stub(:rebuild_acquisition, ->(*) { true }) do
              assert_nothing_raised { ClickhouseRollupRebuildService.rebuild_stale_dirty(watermark_months: 2) }
            end
          end
        end
      end

      assert_includes metrics, ["clickhouse.rollup_rebuild.failed", "catchup"]
      assert_equal %w[202507], ClickhouseRollupRebuildService.dirty_partitions
    end
  end

  test "clear_dirty removes only the given partitions" do
    ClickhouseRollupRebuildService.mark_dirty(Date.new(2026, 6, 1))
    ClickhouseRollupRebuildService.mark_dirty(Date.new(2026, 5, 1))

    ClickhouseRollupRebuildService.clear_dirty(%w[202606])

    assert_equal %w[202605], ClickhouseRollupRebuildService.dirty_partitions
  end

  test "ROLLUPS defines the totals mirrors, attribution rollups, and breakdown rebuilds" do
    # project/link/visitor mirror PG stat-table TOTALS; last_touch + dimension are the
    # Phase 5 partition-scoped attribution rollups; the *_breakdown/country/version/
    # source/property/billing entries are the exact BREAKDOWN rebuilds that replaced the
    # plain-events MVs. visitor_acquisition is UNPARTITIONED and rebuilt by
    # rebuild_acquisition, so it is deliberately NOT in ROLLUPS. link_sessions is the one
    # entry sourced from session_summary rather than events.
    assert_equal %i[
      project link visitor last_touch dimension
      project_breakdown link_breakdown visitor_breakdown country version source property billing
      first_seen link_sessions
    ].sort, ClickhouseRollupRebuildService::ROLLUPS.keys.sort
    assert_not ClickhouseRollupRebuildService::ROLLUPS.key?(:acquisition)
  end

  test "partition rebuild insert is time-bounded below the rebuild lock TTL" do
    select_sql = ClickhouseRollupRebuildService::ROLLUPS.fetch(:project).fetch(:select)
    sql = ClickhouseRollupRebuildService.send(:insert_query, "staging", select_sql, 202606).to_sql

    assert_includes sql,
      "SETTINGS max_execution_time = #{ClickhouseRollupRebuildService::REBUILD_MAX_EXECUTION_SECONDS}"
    assert_includes sql, "max_threads = #{ClickhouseRollupRebuildService::REBUILD_MAX_THREADS}"
    assert_operator ClickhouseRollupRebuildService::REBUILD_MAX_EXECUTION_SECONDS,
      :<, ClickhouseRollupRebuildService::LOCK_TTL
  end

  test "partition rebuild HTTP budget outlives the server-side kill so CH reports the timeout" do
    captured = nil
    Clickhouse.stub(:with_request_timeout, ->(seconds, &_blk) { captured = seconds }) do
      ClickhouseRollupRebuildService.send(
        :do_rebuild_partition, ClickhouseRollupRebuildService::ROLLUPS.fetch(:project), 202606
      )
    end

    assert_equal ClickhouseRollupRebuildService::REBUILD_MAX_EXECUTION_SECONDS + 10, captured
  end

  test "acquisition rebuild query is partition scoped instead of whole-history touched visitor repair" do
    sql = ClickhouseRollupRebuildService.send(:acquisition_insert_query, 202606).to_sql

    assert_includes sql, "INSERT INTO `visitor_acquisition`"
    assert_includes sql, "max_threads = #{ClickhouseRollupRebuildService::REBUILD_MAX_THREADS}"
    assert_includes sql, "WHERE toYYYYMM(toDate(created_at)) = {partition:UInt32}"
    assert_not_includes sql, "WHERE (events.project_id,"
    assert_not_includes sql, "SELECT DISTINCT events.project_id AS pid"
  end

  test "visitor merge acquisition repair query is scoped to project partition and raw visitor ids" do
    sql = ClickhouseRollupRebuildService.send(
      :acquisition_insert_query,
      202606,
      project_id: 7,
      raw_visitor_ids: [10, 20]
    ).to_sql

    assert_includes sql, "events.project_id = {project_id:UInt64}"
    assert_includes sql, "toYYYYMM(toDate(created_at)) = {partition:UInt32}"
    assert_includes sql, "events.visitor_id IN (10,20)"
    assert_not_includes sql, "SELECT DISTINCT events.project_id AS pid"
  end

  test "repair_acquisition_for_visitor_merge discovers partitions and rebuilds only those visitor ids" do
    rebuilt = []
    Clickhouse.stub(:enabled?, true) do
      ClickhouseRollupRebuildService.stub(:acquisition_repair_visitor_ids, lambda { |pid, from, to|
        assert_equal [7, 10, 20], [pid, from, to]
        [10, 20]
      }) do
        ClickhouseRollupRebuildService.stub(:visitor_partitions, lambda { |pid, ids|
          assert_equal 7, pid
          assert_equal [10, 20], ids
          %w[202601 202606]
        }) do
          ClickhouseRollupRebuildService.stub(:rebuild_acquisition, lambda { |partition, project_id:, raw_visitor_ids:|
            rebuilt << [partition, project_id, raw_visitor_ids]
            true
          }) do
            assert_equal %w[202601 202606],
                         ClickhouseRollupRebuildService.repair_acquisition_for_visitor_merge(7, 10, 20)
          end
        end
      end
    end

    assert_equal [
      ["202601", 7, [10, 20]],
      ["202606", 7, [10, 20]]
    ], rebuilt
  end

  test "visitor-scoped repair inserts without a lock — even while the partition rebuild lock is held" do
    held = ClickhouseRollupRebuildService.lock_key_for(:acquisition, "202606")
    REDIS.with { |c| c.set(held, "held", nx: true, ex: 60) }
    executed = []
    fake_conn = Object.new
    fake_conn.define_singleton_method(:execute) { |sql| executed << sql }

    Clickhouse.stub(:enabled?, true) do
      Clickhouse.stub(:with, ->(&blk) { blk.call(fake_conn) }) do
        assert ClickhouseRollupRebuildService.rebuild_acquisition("202606", project_id: 7, raw_visitor_ids: [5])
        assert_not ClickhouseRollupRebuildService.rebuild_acquisition("202606"),
                   "whole-partition rebuild must still respect the lock"
      end
    end
    assert_equal 1, executed.size
  ensure
    REDIS.with { |c| c.del(held) }
  end

  test "repair_acquisition_for_visitor_merge includes visitors already mapped to the final survivor" do
    resolved = []
    captured_sql = nil
    fake_conn = Object.new
    fake_conn.define_singleton_method(:select_all) do |sql|
      captured_sql = sql
      [{ "from_visitor_id" => 10 }, { "from_visitor_id" => 20 }]
    end

    ClickhouseIdentityMapService.stub(:resolve, lambda { |pid, vid|
      resolved = [pid, vid]
      30
    }) do
      Clickhouse.stub(:with, ->(&blk) { blk.call(fake_conn) }) do
        ids = ClickhouseRollupRebuildService.send(:acquisition_repair_visitor_ids, 7, 20, 30)
        assert_equal [7, 30], resolved
        assert_includes captured_sql, "to_visitor_id = 30"
        assert_equal [20, 30, 10], ids
      end
    end
  end

  test "repair_acquisition_for_visitor_merge returns the repaired partitions" do
    Clickhouse.stub(:enabled?, true) do
      ClickhouseRollupRebuildService.stub(:acquisition_repair_visitor_ids, ->(*) { [10, 20] }) do
        ClickhouseRollupRebuildService.stub(:visitor_partitions, ->(*) { %w[202606] }) do
          ClickhouseRollupRebuildService.stub(:rebuild_acquisition, ->(*, **) { true }) do
            assert_equal %w[202606],
                         ClickhouseRollupRebuildService.repair_acquisition_for_visitor_merge(7, 10, 20)
          end
        end
      end
    end
  end

  test "partitions_in_range returns the inclusive month-by-month YYYYMM list" do
    assert_equal %w[202511 202512 202601 202602],
                 ClickhouseRollupRebuildService.partitions_in_range("202511", "202602")
  end

  test "partitions_in_range is order-insensitive and inclusive on a single month" do
    assert_equal %w[202511 202512 202601 202602],
                 ClickhouseRollupRebuildService.partitions_in_range(202602, 202511)
    assert_equal %w[202606], ClickhouseRollupRebuildService.partitions_in_range("202606", "202606")
  end

  test "rebuild_partition_range rebuilds exactly the requested partitions for the requested rollups" do
    seen = []
    ClickhouseRollupRebuildService.stub(:rebuild_partition, ->(rollup, part) { seen << [rollup, part] }) do
      Clickhouse.stub(:enabled?, true) do
        ClickhouseRollupRebuildService.rebuild_partition_range("202604", "202606", rollups: [:project])
      end
    end

    assert_equal [[:project, "202604"], [:project, "202605"], [:project, "202606"]], seen
  end

  test "rebuild_partition_range rebuilds acquisition by default" do
    acquisition_parts = []
    rollup_keys = []
    ClickhouseRollupRebuildService.stub(:rebuild_acquisition, ->(part) { acquisition_parts << part }) do
      ClickhouseRollupRebuildService.stub(:rebuild_partition, ->(rollup, _part) { rollup_keys << rollup }) do
        Clickhouse.stub(:enabled?, true) do
          ClickhouseRollupRebuildService.rebuild_partition_range("202605", "202606")
        end
      end
    end

    assert_equal %w[202605 202606], acquisition_parts
    assert_equal ClickhouseRollupRebuildService::ROLLUPS.keys.sort, rollup_keys.uniq.sort
  end

  test "rebuild_partition_range fail_on_skip: raises when a rebuild is lock-skipped" do
    Clickhouse.stub(:enabled?, true) do
      ClickhouseRollupRebuildService.stub(:rebuild_partition, ->(*) { false }) do
        error = assert_raises(RuntimeError) do
          ClickhouseRollupRebuildService.rebuild_partition_range(
            "202606", "202606", rollups: [:project], strict: true, fail_on_skip: true
          )
        end
        assert_match(/lock held/, error.message)
      end
    end
  end

  test "rebuild_partition_range fail_on_skip: raises when acquisition is lock-skipped" do
    Clickhouse.stub(:enabled?, true) do
      ClickhouseRollupRebuildService.stub(:rebuild_acquisition, ->(*) { false }) do
        error = assert_raises(RuntimeError) do
          ClickhouseRollupRebuildService.rebuild_partition_range(
            "202606", "202606", rollups: [:acquisition], strict: true, fail_on_skip: true
          )
        end
        assert_match(/lock held/, error.message)
      end
    end
  end

  # A raise during the retry is a real failure, not "someone else holds the lock".
  test "rebuild_partition_range fail_on_skip: raises when a retried rebuild errors" do
    calls = 0
    Clickhouse.stub(:enabled?, true) do
      ClickhouseRollupRebuildService.stub(:rebuild_partition, lambda { |*|
        calls += 1
        calls == 1 ? false : raise("boom")
      }) do
        error = assert_raises(RuntimeError) do
          ClickhouseRollupRebuildService.rebuild_partition_range(
            "202606", "202606", rollups: [:project], strict: true, fail_on_skip: true
          )
        end
        assert_match(/boom/, error.message)
      end
    end
  end

  # raise then lock-skip: the error must survive, not be erased by the later benign skip.
  test "rebuild_partition_range fail_on_skip: keeps a retry error that a later skip follows" do
    calls = 0
    Clickhouse.stub(:enabled?, true) do
      ClickhouseRollupRebuildService.stub(:rebuild_partition, lambda { |*|
        calls += 1
        raise "boom" if calls == 2

        false
      }) do
        error = assert_raises(RuntimeError) do
          ClickhouseRollupRebuildService.rebuild_partition_range(
            "202606", "202606", rollups: [:project], strict: true, fail_on_skip: true
          )
        end
        assert_match(/boom/, error.message)
      end
    end
  end

  test "rebuild_partition_range does not wait on locks when skips are benign" do
    waited = false
    Clickhouse.stub(:enabled?, true) do
      capture = lambda do |sk, wait_for_lock: true|
        waited = wait_for_lock
        [sk, []]
      end
      ClickhouseRollupLockRetry.stub(:call, capture) do
        ClickhouseRollupRebuildService.stub(:rebuild_partition, ->(*) { false }) do
          ClickhouseRollupRebuildService.rebuild_partition_range("202606", "202606", rollups: [:project])
        end
      end
    end
    assert_not waited, "a benign skip must not block on the lock"
  end

  test "rebuild_partition_range strict: tolerates a lock-skip without fail_on_skip" do
    Clickhouse.stub(:enabled?, true) do
      ClickhouseRollupRebuildService.stub(:rebuild_partition, ->(*) { false }) do
        assert_equal %w[202606], ClickhouseRollupRebuildService.rebuild_partition_range(
          "202606", "202606", rollups: [:project], strict: true
        )
      end
    end
  end

  test "rebuild_partition_range is a no-op when ClickHouse is disabled" do
    called = false
    ClickhouseRollupRebuildService.stub(:rebuild_partition, ->(*) { called = true }) do
      Clickhouse.stub(:enabled?, false) do
        ClickhouseRollupRebuildService.rebuild_partition_range("202601", "202601")
      end
    end

    assert_not called
  end

  test "mark_dirty logs an observable metric on failure instead of silently swallowing" do
    logged = nil
    Rails.logger.stub(:error, ->(msg) { logged = msg }) do
      ClickhouseRollupRebuildService.stub(:partition_for, ->(*) { raise "redis down" }) do
        result = ClickhouseRollupRebuildService.mark_dirty(Date.new(2026, 6, 1))
        assert_nil result, "mark_dirty must swallow and return nil on failure"
      end
    end

    assert_includes logged, "mark_dirty FAILED"
    assert_includes logged, "clickhouse_rollup_mark_dirty_failed"
  end

  test "mark_dirty_for_visitor falls back to watermark partitions and logs when the discovery query fails" do
    travel_to Time.utc(2026, 6, 26) do
      logged = nil
      Clickhouse.stub(:enabled?, true) do
        Clickhouse.stub(:with, ->(&_blk) { raise StandardError, "query timed out" }) do
          Rails.logger.stub(:error, ->(msg) { logged = msg }) do
            assert_nothing_raised do
              ClickhouseRollupRebuildService.mark_dirty_for_visitor(42, 123)
            end
          end
        end
      end

      # Watermark window (current + previous default_watermark_months) is now dirty
      dirty = ClickhouseRollupRebuildService.dirty_partitions.sort
      assert_includes dirty, "202606"
      assert_includes dirty, "202605"
      assert_includes dirty, "202604"

      assert_includes logged, "mark_dirty_for_visitor FAILED"
    end
  end

  test "default_watermark_months defaults to 2 and is env-configurable" do
    assert_equal 2, ClickhouseRollupRebuildService.default_watermark_months

    ENV["CLICKHOUSE_ROLLUP_WATERMARK_MONTHS"] = "3"
    assert_equal 3, ClickhouseRollupRebuildService.default_watermark_months
  ensure
    ENV.delete("CLICKHOUSE_ROLLUP_WATERMARK_MONTHS")
  end

  test "fast_lane_enabled? reads the env flag" do
    original = ENV["CLICKHOUSE_ROLLUP_FAST_LANE"]
    ENV["CLICKHOUSE_ROLLUP_FAST_LANE"] = "true"
    assert ClickhouseRollupRebuildService.fast_lane_enabled?
    ENV["CLICKHOUSE_ROLLUP_FAST_LANE"] = "false"
    assert_not ClickhouseRollupRebuildService.fast_lane_enabled?
  ensure
    original.nil? ? ENV.delete("CLICKHOUSE_ROLLUP_FAST_LANE") : ENV["CLICKHOUSE_ROLLUP_FAST_LANE"] = original
  end
end
