# frozen_string_literal: true

require "test_helper"

class ClickhouseRollupLivenessTest < ActiveSupport::TestCase
  ROLLUP_SQL = "SELECT count() FROM project_metrics_daily WHERE project_id = 1"
  EVENTS_SQL = "SELECT count() FROM events WHERE project_id = 1"

  setup do
    ClickhouseRollupLiveness.clear!
    Rails.application.config.clickhouse_primary = true
  end

  teardown { ClickhouseRollupLiveness.clear! }

  def with_fast_lane
    ENV["CLICKHOUSE_ROLLUP_FAST_LANE"] = "true"
    yield
  ensure
    ENV.delete("CLICKHOUSE_ROLLUP_FAST_LANE")
  end

  test "a rollup read with no lane stamp raises so a dead rebuild cannot serve zeros" do
    assert_raises(Clickhouse::Stale) { ClickhouseRollupLiveness.gate!(ROLLUP_SQL) }
  end

  test "a fresh full-lane stamp serves" do
    ClickhouseRollupLiveness.record(:full)

    assert_nothing_raised { ClickhouseRollupLiveness.gate!(ROLLUP_SQL) }
  end

  test "the fast lane alone is enough — one dead lane is lag, not a wrong number" do
    with_fast_lane { ClickhouseRollupLiveness.record(:fast) }

    with_fast_lane { assert_nothing_raised { ClickhouseRollupLiveness.gate!(ROLLUP_SQL) } }
  end

  test "both lanes enabled and both unstamped raises" do
    with_fast_lane { assert_raises(Clickhouse::Stale) { ClickhouseRollupLiveness.gate!(ROLLUP_SQL) } }
  end

  test "a disabled fast lane's leftover stamp cannot cover for a dead full lane" do
    with_fast_lane { ClickhouseRollupLiveness.record(:fast) }

    assert_raises(Clickhouse::Stale) { ClickhouseRollupLiveness.gate!(ROLLUP_SQL) }
  end

  test "a fresh full lane serves while the enabled fast lane is stale" do
    ClickhouseRollupLiveness.record(:full)

    with_fast_lane { assert_nothing_raised { ClickhouseRollupLiveness.gate!(ROLLUP_SQL) } }
  end

  test "a stamp older than the threshold is stale" do
    stale_at = Time.current.to_i - ClickhouseRollupLiveness.max_age_seconds - 60
    REDIS.with { |conn| conn.set(ClickhouseRollupLiveness.key(:full), stale_at) }

    assert_raises(Clickhouse::Stale) { ClickhouseRollupLiveness.gate!(ROLLUP_SQL) }
  end

  test "reads of live tables are never gated — a dead rebuild does not make events wrong" do
    assert_nothing_raised { ClickhouseRollupLiveness.gate!(EVENTS_SQL) }
  end

  test "an old partition served from a rollup is fine while a lane is fresh" do
    ClickhouseRollupLiveness.record(:full)
    old_range_sql = "SELECT sum(views) FROM link_daily WHERE event_date >= '2024-01-01'"

    assert_nothing_raised { ClickhouseRollupLiveness.gate!(old_range_sql) }
  end

  test "off primary the gate never raises" do
    Rails.application.config.clickhouse_primary = false

    assert_nothing_raised { ClickhouseRollupLiveness.gate!(ROLLUP_SQL) }
  end

  test "gates a placeholder query object, not just a SQL string" do
    query = ClickHouse::Client::Query.new(
      raw_query: "SELECT sum(cnt) FROM project_daily WHERE project_id = {project_id:UInt64}",
      placeholders: { project_id: 1 }
    )

    assert_raises(Clickhouse::Stale) { ClickhouseRollupLiveness.gate!(query) }
  end

  test "every rebuilt rollup table is gated" do
    tables = ClickhouseRollupRebuildService::ROLLUPS.each_value.map { |config| config[:table] } +
             [ClickhouseRollupRebuildService::ACQUISITION_TABLE]

    tables.each do |table|
      assert ClickhouseRollupLiveness.rollup_sql?("SELECT 1 FROM #{table}"), "#{table} is not gated"
    end
  end

  test "a Redis failure does not 503 analytics on its own" do
    ClickhouseRollupLiveness.stub(:key, ->(_lane) { raise Redis::CannotConnectError }) do
      assert_nothing_raised { ClickhouseRollupLiveness.gate!(ROLLUP_SQL) }
    end
  end

  test "the full lane stamps only a pass that failed nothing" do
    ClickhouseRollupRebuildService.stub(:dirty_partitions, []) do
      ClickhouseRollupRebuildService.stub(:rebuild_partition, true) do
        ClickhouseRollupRebuildService.stub(:rebuild_acquisition, true) do
          Clickhouse.stub(:enabled?, true) { ClickhouseRollupRebuildService.rebuild_all_dirty }
        end
      end
    end

    assert ClickhouseRollupLiveness.fresh?
  end

  test "a failed rollup leaves the full lane unstamped" do
    ClickhouseRollupRebuildService.stub(:dirty_partitions, []) do
      ClickhouseRollupRebuildService.stub(:rebuild_partition, ->(*) { raise "boom" }) do
        ClickhouseRollupRebuildService.stub(:rebuild_acquisition, true) do
          Clickhouse.stub(:enabled?, true) { ClickhouseRollupRebuildService.rebuild_all_dirty }
        end
      end
    end

    assert_not ClickhouseRollupLiveness.fresh?
  end
end
