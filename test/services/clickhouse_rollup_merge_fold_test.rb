# frozen_string_literal: true

require "test_helper"

# CH-gated Phase 4: after a visitor merge is recorded in the identity map, the
# rollup rebuild folds the merged visitor's canonical events under the survivor
# (applied BEFORE aggregation), with no double-counting and no merged visitor_id
# left in the rollup. Canonical rows are never mutated.
class ClickhouseRollupMergeFoldTest < ActiveSupport::TestCase
  include ClickhouseTestHelper

  PROJECT_ID = 7401
  SURVIVOR = 100
  MERGED = 200
  MERGED_B = 300
  DEVICE = 5555

  setup do
    skip_unless_clickhouse!
    REDIS.with { |c| c.del(ClickhouseRollupRebuildService.dirty_key) }
  end

  teardown do
    REDIS.with { |c| c.del(ClickhouseRollupRebuildService.dirty_key) }
  end

  test "un-merged visitor passes through effective_visitor_id unchanged" do
    seed([view(SURVIVOR, "s1"), view(SURVIVOR, "s2")])
    rebuild_visitor!

    rows = visitor_rows
    assert_equal 1, rows.size
    assert_equal SURVIVOR, rows.first["visitor_id"].to_i
    assert_equal 2, rows.first["views"].to_i
  end

  test "after a merge the survivor row folds in the merged visitor's events; merged id absent" do
    # survivor: 2 views; merged: 3 views. Both on the same day.
    seed([
      view(SURVIVOR, "s1"), view(SURVIVOR, "s2"),
      view(MERGED, "m1"), view(MERGED, "m2"), view(MERGED, "m3")
    ])
    ClickhouseIdentityMapService.record_merge(PROJECT_ID, MERGED, SURVIVOR)
    rebuild_visitor!

    rows = visitor_rows
    assert_equal 1, rows.size, "merged visitor_id must not appear as its own row"
    assert_equal SURVIVOR, rows.first["visitor_id"].to_i
    assert_equal 5, rows.first["views"].to_i, "survivor = sum of both, not double-counted"
  end

  test "chain merge A->B->C folds A's and B's events under C (path compression proven)" do
    seed([
      view(SURVIVOR, "c1"),                 # C: 1 view
      view(MERGED_B, "b1"), view(MERGED_B, "b2"), # B: 2 views
      view(MERGED, "a1")                    # A: 1 view
    ])
    ClickhouseIdentityMapService.record_merge(PROJECT_ID, MERGED, MERGED_B)  # A->B
    ClickhouseIdentityMapService.record_merge(PROJECT_ID, MERGED_B, SURVIVOR) # B->C
    rebuild_visitor!

    rows = visitor_rows
    assert_equal 1, rows.size
    assert_equal SURVIVOR, rows.first["visitor_id"].to_i
    assert_equal 4, rows.first["views"].to_i, "A + B + C events all fold under C"
  end

  test "recording the merge twice yields the same rollup (no double count)" do
    seed([view(SURVIVOR, "s1"), view(MERGED, "m1"), view(MERGED, "m2")])
    ClickhouseIdentityMapService.record_merge(PROJECT_ID, MERGED, SURVIVOR)
    ClickhouseIdentityMapService.record_merge(PROJECT_ID, MERGED, SURVIVOR)
    rebuild_visitor!

    rows = visitor_rows
    assert_equal 1, rows.size
    assert_equal 3, rows.first["views"].to_i
  end

  test "the project rollup also folds merged visitors into unique_visitors via the survivor" do
    seed([view(SURVIVOR, "s1"), view(MERGED, "m1")])
    ClickhouseIdentityMapService.record_merge(PROJECT_ID, MERGED, SURVIVOR)
    ClickhouseRollupRebuildService.rebuild_partition(:project, "202606")

    row = ch_query("project_metrics_daily", PROJECT_ID).first
    assert_equal 2, row["views"].to_i
    assert_equal 1, row["unique_visitors"].to_i, "merged + survivor count once, under survivor"
  end

  test "bounded acquisition repair folds six stored states instead of rescanning canonical events" do
    seed([
      view(MERGED, "z").merge(event_type: "install", campaign_id: 0, link_id: 1),
      view(SURVIVOR, "a").merge(event_type: "install", campaign_id: 1),
      view(MERGED, "touch").merge(created_at: "2026-05-01 00:00:00.000", link_id: 1)
    ])
    %w[202605 202606].each { |part| ClickhouseRollupRebuildService.rebuild_acquisition(part) }
    ClickhouseIdentityMapService.record_merge(PROJECT_ID, MERGED, SURVIVOR)
    3.times do
      assert ClickhouseRollupRebuildService.rebuild_acquisition("202606", project_id: PROJECT_ID, raw_visitor_ids: [MERGED, SURVIVOR])
    end
    actual = acquisition_rows("visitor_acquisition", [SURVIVOR])
    assert_equal "campaigns", actual.first.fetch("install_source")
    assert_equal "links", actual.first.fetch("first_touch_source")
    assert_equal canonical_acquisition([SURVIVOR], %w[202605 202606]), actual
  end

  test "acquisition entry point includes ancestor states for chained merges" do
    seed([
      view(MERGED, "first").merge(event_type: "install", created_at: "2026-06-01 00:00:00.000", campaign_id: 1),
      view(MERGED_B, "middle").merge(event_type: "install", link_id: 1),
      view(SURVIVOR, "last").merge(event_type: "install")
    ])
    ClickhouseRollupRebuildService.rebuild_acquisition("202606")
    rebuild_visitor!
    ClickhouseIdentityMapService.record_merge(PROJECT_ID, MERGED, MERGED_B)
    ClickhouseIdentityMapService.record_merge(PROJECT_ID, MERGED_B, SURVIVOR)
    ClickhouseRollupRebuildService.repair_acquisition_for_visitor_merge(PROJECT_ID, MERGED_B, SURVIVOR)
    assert_equal canonical_acquisition([SURVIVOR], ["202606"]), acquisition_rows("visitor_acquisition", [SURVIVOR])
  end

  test "acquisition repair preserves summaries after canonical retention and stays project scoped" do
    seed([view(MERGED, "old").merge(event_type: "install", campaign_id: 1)])
    seed([view(MERGED, "other").merge(project_id: PROJECT_ID + 1, event_type: "install", link_id: 1, created_at: "2026-06-01 00:00:00.000")])
    ClickhouseRollupRebuildService.rebuild_acquisition("202606")
    Clickhouse.with { |conn| conn.execute("ALTER TABLE events DROP PARTITION 202606") }
    ClickhouseIdentityMapService.record_merge(PROJECT_ID, MERGED, SURVIVOR)
    ClickhouseRollupRebuildService.rebuild_acquisition("202606", project_id: PROJECT_ID, raw_visitor_ids: [MERGED, SURVIVOR])
    row = acquisition_rows("visitor_acquisition", [SURVIVOR]).first
    assert_equal "campaigns", row.fetch("install_source")
    assert_equal "campaigns", row.fetch("first_touch_source")
  end

  test "merge folds existing summaries even when partition discovery is empty" do
    seed([view(MERGED, "summary-only").merge(event_type: "install", campaign_id: 1)])
    ClickhouseRollupRebuildService.rebuild_acquisition("202606")
    ClickhouseIdentityMapService.record_merge(PROJECT_ID, MERGED, SURVIVOR)
    assert_equal [], ClickhouseRollupRebuildService.repair_acquisition_for_visitor_merge(PROJECT_ID, MERGED, SURVIVOR)
    assert_equal canonical_acquisition([SURVIVOR], ["202606"]), acquisition_rows("visitor_acquisition", [SURVIVOR])
  end

  test "acquisition repair preserves empty conditional states" do
    seed([view(MERGED, "empty")])
    ClickhouseRollupRebuildService.rebuild_acquisition("202606")
    ClickhouseIdentityMapService.record_merge(PROJECT_ID, MERGED, SURVIVOR)
    ClickhouseRollupRebuildService.rebuild_acquisition("202606", project_id: PROJECT_ID, raw_visitor_ids: [MERGED, SURVIVOR])
    assert_equal canonical_acquisition([SURVIVOR], ["202606"]), acquisition_rows("visitor_acquisition", [SURVIVOR])
  end

  test "late canonical events still require their normal partition rebuild" do
    seed([view(MERGED, "known").merge(event_type: "install", link_id: 1)])
    ClickhouseRollupRebuildService.rebuild_acquisition("202606")
    ClickhouseIdentityMapService.record_merge(PROJECT_ID, MERGED, SURVIVOR)
    seed([view(MERGED, "late").merge(event_type: "install", created_at: "2026-05-01 00:00:00.000", campaign_id: 1)])
    ClickhouseRollupRebuildService.rebuild_acquisition("202606", project_id: PROJECT_ID, raw_visitor_ids: [MERGED, SURVIVOR])
    assert_equal "links", acquisition_rows("visitor_acquisition", [SURVIVOR]).first.fetch("install_source")
    ClickhouseRollupRebuildService.rebuild_acquisition("202605")
    assert_equal canonical_acquisition([SURVIVOR], %w[202605 202606]), acquisition_rows("visitor_acquisition", [SURVIVOR])
  end

  private

  def acquisition_rows(table, ids)
    Clickhouse.with do |conn|
      conn.select_all(<<~SQL)
        SELECT visitor_id, argMinIfMerge(install_source) AS install_source,
          argMinIfMerge(first_touch_source) AS first_touch_source,
          maxIfMerge(has_install) AS has_install, maxIfMerge(has_link) AS has_link,
          minIfMerge(install_ts) AS install_ts, minIfMerge(first_ts) AS first_ts
        FROM #{table} WHERE project_id = #{PROJECT_ID} AND visitor_id IN (#{ids.join(',')})
        GROUP BY project_id, visitor_id ORDER BY visitor_id
      SQL
    end
  end

  def canonical_acquisition(ids, partitions)
    Clickhouse.with do |conn|
      conn.execute("CREATE TABLE acquisition_test_oracle AS visitor_acquisition")
      partitions.each do |part|
        query = ClickhouseRollupRebuildService.send(:acquisition_insert_query, Integer(part))
        conn.execute(ClickHouse::Client::Query.new(
          raw_query: query.to_sql.sub("`visitor_acquisition`", "acquisition_test_oracle"), placeholders: {partition: Integer(part)}
        ))
      end
    end
    acquisition_rows("acquisition_test_oracle", ids)
  ensure
    Clickhouse.with { |conn| conn.execute("DROP TABLE IF EXISTS acquisition_test_oracle") }
  end

  def rebuild_visitor!
    ClickhouseRollupRebuildService.rebuild_partition(:visitor, "202606")
  end

  def visitor_rows
    ch_query("visitor_metrics_daily", PROJECT_ID)
  end

  test "visitor partition discovery reads the visitor-keyed rollup, not the events table" do
    Clickhouse.with do |conn|
      conn.insert("visitor_metrics_daily", [
        { project_id: PROJECT_ID, visitor_id: SURVIVOR, event_date: "2025-01-15", platform: "ios" },
        { project_id: PROJECT_ID, visitor_id: MERGED, event_date: "2025-03-02", platform: "ios" }
      ])
    end

    partitions = ClickhouseRollupRebuildService.send(
      :visitor_partitions, PROJECT_ID, [SURVIVOR, MERGED]
    )

    assert_equal %w[202501 202503], partitions.sort
  end

  test "mark_dirty_for_visitor discovers from the rollup and marks those partitions dirty" do
    Clickhouse.with do |conn|
      conn.insert("visitor_metrics_daily", [
        { project_id: PROJECT_ID, visitor_id: SURVIVOR, event_date: "2024-11-20", platform: "ios" }
      ])
    end

    returned = ClickhouseRollupRebuildService.mark_dirty_for_visitor(PROJECT_ID, SURVIVOR)
    dirty = REDIS.with { |c| c.smembers(ClickhouseRollupRebuildService.dirty_key) }

    # Live-edge months are the watermark lanes' job, not dirty-marking's.
    assert_equal ["202411"], returned
    assert_equal ["202411"], dirty
  end

  test "discovery for an unknown visitor is empty — live months are the watermark lane's job" do
    assert_equal [], ClickhouseRollupRebuildService.send(:visitor_partitions, PROJECT_ID, [999_999])
  end

  test "mark_dirty_for_visitor marks nothing for an unknown visitor" do
    assert_equal [], ClickhouseRollupRebuildService.mark_dirty_for_visitor(PROJECT_ID, 999_999)
    assert_empty REDIS.with { |c| c.smembers(ClickhouseRollupRebuildService.dirty_key) }
  end

  def seed(rows)
    ClickhouseWriteService.insert_canonical_events(rows)
  end

  def view(visitor_id, event_id)
    {
      project_id: PROJECT_ID, visitor_id: visitor_id, device_id: DEVICE,
      inviter_id: 0, platform: "ios", created_at: "2026-06-10 12:00:00.000",
      event_id: event_id, event_type: "view", link_id: 0, engagement_time: 0
    }
  end
end
