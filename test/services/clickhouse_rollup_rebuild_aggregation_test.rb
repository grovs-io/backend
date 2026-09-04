# frozen_string_literal: true

require "test_helper"

# CH-gated: the rebuild aggregates the deduped canonical store EXACTLY, never
# inflates on duplicate delivery, and is idempotent under re-run.
class ClickhouseRollupRebuildAggregationTest < ActiveSupport::TestCase
  include ClickhouseTestHelper

  PROJECT_ID = 7001
  LINK_ID = 4242
  VISITOR_ID = 9090

  setup do
    skip_unless_clickhouse!
    REDIS.with { |c| c.del(ClickhouseRollupRebuildService.dirty_key) }
  end

  teardown do
    REDIS.with { |c| c.del(ClickhouseRollupRebuildService.dirty_key) }
  end

  test "project rollup matches a trusted recompute of canonical" do
    seed_canonical(canonical_events)
    rebuild!

    row = project_rows.first
    assert_equal 3, row["views"].to_i        # 3 view events
    assert_equal 1, row["opens"].to_i
    assert_equal 1, row["installs"].to_i
    assert_equal 1, row["app_opens"].to_i
    assert_equal 1, row["unique_visitors"].to_i
    assert_equal 1, row["unique_devices"].to_i
    # Project rollup carries ONLY directly-countable columns PG can produce — no
    # time_spent/reactivations/user_referred (daily_project_metrics has no such cols).
    assert_not row.key?("time_spent"), "project rollup must not carry time_spent"
  end

  test "project rollup carries only the directly-countable columns" do
    seed_canonical(canonical_events)
    rebuild!

    cols = project_rows.first.keys
    assert_equal(
      %w[project_id event_date platform views opens installs reinstalls app_opens unique_visitors unique_devices].sort,
      cols.sort
    )
  end

  test "link rollup matches a trusted recompute and excludes link_id=0 events" do
    seed_canonical(canonical_events)
    rebuild!

    row = link_rows.first
    assert_equal LINK_ID, row["link_id"].to_i
    assert_equal 2, row["views"].to_i         # only the 2 view events carrying this link_id
    assert_equal 1, row["installs"].to_i
  end

  test "visitor rollup matches a trusted recompute and carries inviter_id" do
    seed_canonical(canonical_events)
    rebuild!

    row = visitor_rows.first
    assert_equal VISITOR_ID, row["visitor_id"].to_i
    assert_equal 3, row["views"].to_i
    assert_equal 1, row["installs"].to_i
    assert_equal 55, row["inviter_id"].to_i
  end

  test "a duplicate row in canonical does NOT inflate any rollup" do
    events = canonical_events
    seed_canonical(events)
    seed_canonical([events.first]) # re-deliver the first event (same event_id)
    rebuild!

    assert_equal 3, project_rows.first["views"].to_i
    assert_equal 2, link_rows.first["views"].to_i
    assert_equal 3, visitor_rows.first["views"].to_i
    # inviter_id stays the single deduped value, not doubled/summed.
    assert_equal 55, visitor_rows.first["inviter_id"].to_i
  end

  test "concurrent rebuilds of the same partition leave a correct, non-doubled rollup" do
    seed_canonical(canonical_events)

    threads = Array.new(2) do
      Thread.new { ClickhouseRollupRebuildService.rebuild_partition(:visitor, "202606") }
    end
    threads.each(&:join)

    rows = visitor_rows
    assert_equal 1, rows.size, "expected exactly one visitor row, not doubled"
    assert_equal 3, rows.first["views"].to_i
    assert_equal 1, rows.first["installs"].to_i
  end

  test "staging table is cleaned up when a rebuild fails mid-flight, and the next rebuild succeeds" do
    seed_canonical(canonical_events)

    # Inject an invalid INSERT so the staging CREATE succeeds but the INSERT step
    # blows up mid-rebuild; the staging-drop ensure must still fire so no orphan
    # staging table is left behind.
    raised = false
    bad_insert = lambda do |staging, *|
      ClickHouse::Client::Query.new(
        raw_query: "INSERT INTO `#{staging}` SELECT no_such_column FROM events",
        placeholders: {}
      )
    end
    ClickhouseRollupRebuildService.stub(:insert_query, bad_insert) do
      ClickhouseRollupRebuildService.rebuild_partition(:project, "202606")
    rescue StandardError
      raised = true
    end

    assert raised, "the injected failure should have propagated"
    assert_empty staging_tables_for("project_metrics_daily"), "no orphan staging table may remain"

    # A subsequent rebuild then succeeds (no 'table exists' / stale staging).
    ClickhouseRollupRebuildService.rebuild_partition(:project, "202606")
    assert_equal 3, project_rows.first["views"].to_i
  end

  def staging_tables_for(table)
    Clickhouse.with do |conn|
      conn.select_all(
        "SELECT name FROM system.tables WHERE database = currentDatabase() " \
        "AND name LIKE '#{table}_staging_%'"
      )
    end
  end

  test "rebuild_partition_range strict: raises on any failure (cutover path must not report green)" do
    seed_canonical(canonical_events)

    bad_insert = lambda do |staging, *|
      ClickHouse::Client::Query.new(
        raw_query: "INSERT INTO `#{staging}` SELECT no_such_column FROM events", placeholders: {}
      )
    end

    ClickhouseRollupRebuildService.stub(:insert_query, bad_insert) do
      assert_raises(RuntimeError) do
        ClickhouseRollupRebuildService.rebuild_partition_range("202606", "202606", rollups: [:project], strict: true)
      end
    end
  end

  test "rebuild_partition_range default (non-strict) swallows failures and returns partitions" do
    seed_canonical(canonical_events)

    bad_insert = lambda do |staging, *|
      ClickHouse::Client::Query.new(
        raw_query: "INSERT INTO `#{staging}` SELECT no_such_column FROM events", placeholders: {}
      )
    end

    result = ClickhouseRollupRebuildService.stub(:insert_query, bad_insert) do
      ClickhouseRollupRebuildService.rebuild_partition_range("202606", "202606", rollups: [:project])
    end
    assert_equal %w[202606], result, "non-strict path stays best-effort for the maintenance/dirty cron"
  end

  test "rebuild is idempotent — running twice yields identical contents" do
    seed_canonical(canonical_events)
    rebuild!
    first = [project_rows, link_rows, visitor_rows]
    rebuild!
    second = [project_rows, link_rows, visitor_rows]

    assert_equal first, second
  end

  test "rebuild only touches partitions it is told to rebuild" do
    # June event, rebuild only May → June rollup stays empty.
    seed_canonical(canonical_events)
    ClickhouseRollupRebuildService.rebuild_partition(:project, "202605")

    assert_empty project_rows
  end

  test "rebuild_all_dirty rebuilds the watermark window and clears its dirty marks" do
    seed_canonical(canonical_events)
    ClickhouseRollupRebuildService.mark_dirty(Date.new(2026, 6, 10))

    travel_to Time.utc(2026, 6, 26) do
      ClickhouseRollupRebuildService.rebuild_all_dirty(watermark_months: 0)
    end

    assert_equal 3, project_rows.first["views"].to_i
    assert_empty ClickhouseRollupRebuildService.dirty_partitions
  end

  private

  def rebuild!
    ClickhouseRollupRebuildService.rebuild_partition(:project, "202606")
    ClickhouseRollupRebuildService.rebuild_partition(:link, "202606")
    ClickhouseRollupRebuildService.rebuild_partition(:visitor, "202606")
  end

  def project_rows
    ch_query("project_metrics_daily", PROJECT_ID)
  end

  def link_rows
    ch_query("link_metrics_daily", PROJECT_ID)
  end

  def visitor_rows
    ch_query("visitor_metrics_daily", PROJECT_ID)
  end

  def seed_canonical(rows)
    ClickhouseWriteService.insert_canonical_events(rows)
  end

  # One visitor/device on one day (2026-06-10), platform ios:
  #   3 views (2 carry the link), 1 open, 1 install (carries link), 1 app_open,
  #   2 time_spent (10s + 15s). inviter_id 55 on the events.
  def canonical_events
    base = {
      project_id: PROJECT_ID, visitor_id: VISITOR_ID, device_id: 1234,
      inviter_id: 55, platform: "ios", created_at: "2026-06-10 12:00:00.000"
    }
    [
      ev(base, "evt-v1", "view", link_id: LINK_ID),
      ev(base, "evt-v2", "view", link_id: LINK_ID),
      ev(base, "evt-v3", "view", link_id: 0),
      ev(base, "evt-o1", "open", link_id: 0),
      ev(base, "evt-i1", "install", link_id: LINK_ID),
      ev(base, "evt-a1", "app_open", link_id: 0),
      ev(base, "evt-t1", "time_spent", link_id: 0, engagement_time: 10),
      ev(base, "evt-t2", "time_spent", link_id: 0, engagement_time: 15)
    ]
  end

  def ev(base, event_id, event_type, link_id:, engagement_time: 0)
    base.merge(event_id: event_id, event_type: event_type, link_id: link_id, engagement_time: engagement_time)
  end
end
