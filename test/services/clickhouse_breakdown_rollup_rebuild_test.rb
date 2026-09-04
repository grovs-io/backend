# frozen_string_literal: true

require "test_helper"

# CH-gated: the BREAKDOWN rollups (the Aggregating/Summing tables the dashboards
# read) are now rebuilt from the deduped canonical store instead of MV-fed from
# plain events. Verifies each rebuild produces exact values, dedups replays, and
# is merge-aware (resolves the identity map before counting visitors).
class ClickhouseBreakdownRollupRebuildTest < ActiveSupport::TestCase
  include ClickhouseTestHelper

  PROJECT_ID = 8201
  LINK_ID = 5252
  VISITOR_ID = 3030
  DEVICE_ID = 4040
  PARTITION = "202606"

  setup do
    skip_unless_clickhouse!
    truncate_clickhouse_tables
    REDIS.with { |c| c.del(ClickhouseRollupRebuildService.dirty_key) }
  end

  teardown do
    REDIS.with { |c| c.del(ClickhouseRollupRebuildService.dirty_key) }
  end

  test "project_daily breakdown: exact per-event_type counts, engagement, uniq visitors/devices" do
    seed_canonical(canonical_events)
    rebuild!

    by_type = project_daily_by_type
    assert_equal 3, by_type.dig("view", "cnt")
    assert_equal 1, by_type.dig("open", "cnt")
    assert_equal 1, by_type.dig("install", "cnt")
    assert_equal 2, by_type.dig("time_spent", "cnt")
    assert_equal 25, by_type.dig("time_spent", "engagement")
    assert_equal 1, by_type.dig("view", "visitors")
    assert_equal 1, by_type.dig("view", "devices")
  end

  test "link_daily breakdown: only link-bearing events, per event_type" do
    seed_canonical(canonical_events)
    rebuild!

    rows = ch_query("link_daily", PROJECT_ID)
    assert rows.all? { |r| r["link_id"].to_i == LINK_ID }, "link_daily must exclude link_id=0 events"
    by_type = rows.group_by { |r| r["event_type"] }.transform_values { |rs| rs.sum { |r| r["cnt"].to_i } }
    assert_equal 2, by_type["view"]     # 2 of the 3 views carry the link
    assert_equal 1, by_type["install"]
  end

  test "visitor_daily breakdown: per-visitor counts + inviter" do
    seed_canonical(canonical_events)
    rebuild!

    rows = ch_query("visitor_daily", PROJECT_ID)
    assert rows.all? { |r| r["visitor_id"].to_i == VISITOR_ID }
    views = rows.select { |r| r["event_type"] == "view" }.sum { |r| r["cnt"].to_i }
    assert_equal 3, views
    assert_equal 55, rows.map { |r| r["inviter_id_state"].to_i }.max
  end

  test "source breakdown: SourceTaxonomy labels, exact uniq visitors" do
    seed_canonical(canonical_events)
    rebuild!

    by_source = merge_rows(
      "SELECT source, sum(cnt) AS cnt, uniqMerge(visitors_state) AS visitors " \
      "FROM project_source_daily WHERE project_id = #{PROJECT_ID} GROUP BY source"
    ).index_by { |r| r["source"] }
    assert_equal 3, by_source.dig("links", "cnt").to_i      # 2 views + 1 install carry the link
    assert_equal 5, by_source.dig("organic", "cnt").to_i    # the rest
    assert_equal 1, by_source.dig("links", "visitors").to_i
  end

  test "version breakdown: first_seen = min(created_at) for the version" do
    seed_canonical(canonical_events)
    rebuild!

    row = merge_rows(
      "SELECT app_version, sum(cnt) AS cnt, uniqMerge(visitors_state) AS visitors, " \
      "min(first_seen) AS first_seen FROM project_version_daily " \
      "WHERE project_id = #{PROJECT_ID} GROUP BY app_version"
    ).first
    assert_equal 8, row["cnt"].to_i
    assert_equal 1, row["visitors"].to_i
    assert_includes row["first_seen"].to_s, "2026-06-10"
  end

  test "property breakdown: curated plan/tier buckets from JSON, empties dropped" do
    seed_canonical([
      canonical_base.merge(event_id: "p1", event_type: "view", properties: { plan: "pro", tier: "gold" }),
      canonical_base.merge(event_id: "p2", event_type: "view", properties: { plan: "pro" }),
      canonical_base.merge(event_id: "p3", event_type: "view", properties: {})
    ])
    rebuild!

    rows = merge_rows(
      "SELECT property_key, property_value, sum(cnt) AS cnt FROM project_property_daily " \
      "WHERE project_id = #{PROJECT_ID} GROUP BY property_key, property_value"
    ).index_by { |r| [r["property_key"], r["property_value"]] }
    assert_equal 2, rows.dig(%w[plan pro], "cnt").to_i  # p1 + p2
    assert_equal 1, rows.dig(%w[tier gold], "cnt").to_i # p1 only; p2/p3 empty tier dropped
    assert_nil rows[%w[plan]], "empty plan/tier values must be filtered out"
  end

  test "billing breakdown is merge-aware: a web->mobile merge counts ONE MAU" do
    web_visitor = 7001
    mobile_visitor = 7002
    seed_canonical([
      canonical_base.merge(event_id: "b1", event_type: "open", visitor_id: web_visitor),
      canonical_base.merge(event_id: "b2", event_type: "open", visitor_id: mobile_visitor)
    ])
    # Alias web -> mobile in the identity map.
    ClickhouseWriteService.insert_identity_rows([{
      project_id: PROJECT_ID, from_visitor_id: web_visitor, to_visitor_id: mobile_visitor,
      updated_at: "2026-06-10 12:05:00.000"
    }])
    rebuild!

    active = merge_rows(
      "SELECT uniqExactMerge(visitors_state) AS mau FROM billing_active_visitors_daily " \
      "WHERE project_id = #{PROJECT_ID}"
    ).first["mau"].to_i
    assert_equal 1, active, "merged web+mobile visitor must count as one active visitor"
  end

  test "duplicate canonical delivery does not inflate a breakdown rollup" do
    seed_canonical(canonical_events)
    seed_canonical([canonical_events.first]) # replay same event_id
    rebuild!

    assert_equal 3, project_daily_by_type.dig("view", "cnt"), "FINAL must collapse the replay"
  end

  private

  def rebuild!
    ClickhouseRollupRebuildService.rebuild_partition_range(
      PARTITION, PARTITION,
      rollups: %i[project_breakdown link_breakdown visitor_breakdown country version source property billing]
    )
  end

  def project_daily_by_type
    merge_rows(
      "SELECT event_type, sum(cnt) AS cnt, sum(total_engagement_time) AS engagement, " \
      "uniqMerge(visitors_state) AS visitors, uniqMerge(devices_state) AS devices " \
      "FROM project_daily WHERE project_id = #{PROJECT_ID} GROUP BY event_type"
    ).each_with_object({}) do |r, h|
      h[r["event_type"]] = {
        "cnt" => r["cnt"].to_i, "engagement" => r["engagement"].to_i,
        "visitors" => r["visitors"].to_i, "devices" => r["devices"].to_i
      }
    end
  end

  def merge_rows(sql)
    Clickhouse.with { |conn| conn.select_all(sql) }.to_a
  end

  def seed_canonical(rows)
    ClickhouseWriteService.insert_canonical_events(rows)
  end

  def canonical_base
    {
      project_id: PROJECT_ID, visitor_id: VISITOR_ID, device_id: DEVICE_ID,
      inviter_id: 55, platform: "ios", created_at: "2026-06-10 12:00:00.000"
    }
  end

  def canonical_events
    [
      ev("evt-v1", "view", link_id: LINK_ID),
      ev("evt-v2", "view", link_id: LINK_ID),
      ev("evt-v3", "view", link_id: 0),
      ev("evt-o1", "open", link_id: 0),
      ev("evt-i1", "install", link_id: LINK_ID),
      ev("evt-a1", "app_open", link_id: 0),
      ev("evt-t1", "time_spent", link_id: 0, engagement_time: 10),
      ev("evt-t2", "time_spent", link_id: 0, engagement_time: 15)
    ]
  end

  def ev(event_id, event_type, link_id:, engagement_time: 0)
    canonical_base.merge(event_id: event_id, event_type: event_type, link_id: link_id, engagement_time: engagement_time)
  end
end
