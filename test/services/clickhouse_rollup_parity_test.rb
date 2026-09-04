# frozen_string_literal: true

require "test_helper"

# CH-gated: parity between the CH rollups and the live PG stat tables, per metric.
# This is the trusted oracle that gates the eventual Phase 6 cutover.
class ClickhouseRollupParityTest < ActiveSupport::TestCase
  include ClickhouseTestHelper

  fixtures :instances, :projects

  PLATFORM = "ios"

  setup do
    skip_unless_clickhouse!
    @project = projects(:one)
    @date = Date.new(2026, 6, 10)
    REDIS.with { |c| c.del(ClickhouseRollupRebuildService.dirty_key) }
  end

  teardown do
    REDIS.with { |c| c.del(ClickhouseRollupRebuildService.dirty_key) }
  end

  test "visitor rollup parity reports match when CH and PG agree" do
    seed_pg_visitor(views: 3, installs: 1, opens: 2)
    seed_ch_visitor(views: 3, installs: 1, opens: 2)

    results = Billing::ClickhouseParityCheck.rollup_parity(
      rollup: :visitor, project_id: @project.id, start_date: @date, end_date: @date
    )

    assert results[:views].match?, results[:views].inspect
    assert results[:installs].match?
    assert results[:opens].match?
  end

  test "visitor rollup parity reports a non-zero diff when CH and PG disagree" do
    seed_pg_visitor(views: 5)
    seed_ch_visitor(views: 3)

    results = Billing::ClickhouseParityCheck.rollup_parity(
      rollup: :visitor, project_id: @project.id, start_date: @date, end_date: @date
    )

    assert_not results[:views].match?
    assert_equal(-2, results[:views].delta)
    assert_equal "mismatch", results[:views].status
  end

  test "link rollup parity matches when CH and PG agree" do
    seed_pg_link(views: 4, installs: 2)
    seed_ch_link(views: 4, installs: 2)

    results = Billing::ClickhouseParityCheck.rollup_parity(
      rollup: :link, project_id: @project.id, start_date: @date, end_date: @date
    )

    assert results[:views].match?
    assert results[:installs].match?
  end

  test "project parity explicitly reports uncovered columns and does not silently pass them" do
    results = Billing::ClickhouseParityCheck.rollup_parity(
      rollup: :project, project_id: @project.id, start_date: @date, end_date: @date
    )

    # Only derived (per-day) + referred_users (range-distinct) stay covered at project
    # grain — countables and the first-seen pair are graded against stale DPM (e070995, 37504ea).
    assert_equal %i[organic_users link_views referred_users].sort, results.keys.sort

    uncovered = results.uncovered
    %i[views opens installs reinstalls app_opens new_users first_time_visitors
       returning_users revenue units_sold].each do |col|
      assert uncovered.key?(col), "#{col} must be reported as uncovered"
      assert uncovered[col].present?, "#{col} must carry a reason"
      assert_nil results[col], "#{col} must NOT be silently covered"
    end
    %i[organic_users link_views referred_users].each do |col|
      assert_not uncovered.key?(col), "#{col} is now covered"
    end
  end

  test "visitor parity covers the full event-countable metric set" do
    results = Billing::ClickhouseParityCheck.rollup_parity(
      rollup: :visitor, project_id: @project.id, start_date: @date, end_date: @date
    )

    assert_equal(
      %i[views opens installs reinstalls time_spent reactivations app_opens user_referred].sort,
      results.keys.sort
    )
    assert results.uncovered.key?(:revenue), "revenue is the only uncovered visitor column"
  end

  test "referred_users parity compares distinct people on both sides, not visitor-days" do
    inviter_id = 4242
    # Same visitor referred, active on TWO days: 1 person, 2 rows.
    [@date, @date + 1].each do |d|
      ActiveRecord::Base.connection.execute(
        ActiveRecord::Base.sanitize_sql_array([
          "INSERT INTO visitor_daily_statistics (visitor_id, project_id, event_date, platform, " \
          "invited_by_id, views, created_at, updated_at) VALUES (?, ?, ?, ?, ?, 1, NOW(), NOW())",
          VISITOR_ID, @project.id, d, PLATFORM, inviter_id
        ])
      )
    end
    Clickhouse.with do |conn|
      conn.insert("visitor_metrics_daily", [@date, @date + 1].map do |d|
        { project_id: @project.id, visitor_id: VISITOR_ID, event_date: d.to_s, platform: PLATFORM,
          views: 1, opens: 0, installs: 0, reinstalls: 0, time_spent: 0,
          reactivations: 0, app_opens: 0, user_referred: 0, inviter_id: inviter_id }
      end)
    end

    results = Billing::ClickhouseParityCheck.rollup_parity(
      rollup: :project, project_id: @project.id, start_date: @date, end_date: @date + 1
    )

    assert_equal 1, results[:referred_users].postgres_count, "one person, not two visitor-days"
    assert_equal 1, results[:referred_users].clickhouse_count
    assert results[:referred_users].match?
  end

  test "link_daily parity pivots event_type counts onto the PG counter columns" do
    seed_pg_link(views: 4, installs: 2)
    seed_ch_link_daily("view" => 4, "install" => 2)

    results = Billing::ClickhouseParityCheck.rollup_parity(
      rollup: :link_events, project_id: @project.id, start_date: @date, end_date: @date
    )

    assert results[:views].match?, results[:views].inspect
    assert results[:installs].match?
    # time_spent means seconds in PG and events in link_daily — declared, not compared.
    assert results.uncovered.key?(:time_spent)
    assert_nil results[:time_spent]
  end

  test "link_daily parity reports a diff when it disagrees with the PG counters" do
    seed_pg_link(views: 4)
    seed_ch_link_daily("view" => 1)

    results = Billing::ClickhouseParityCheck.rollup_parity(
      rollup: :link_events, project_id: @project.id, start_date: @date, end_date: @date
    )

    assert_not results[:views].match?
    assert_equal(-3, results[:views].delta)
  end

  test "link parity covers the countable set and marks revenue and time_spent uncovered" do
    results = Billing::ClickhouseParityCheck.rollup_parity(
      rollup: :link, project_id: @project.id, start_date: @date, end_date: @date
    )

    assert_equal(
      %i[views opens installs reinstalls reactivations app_opens user_referred].sort,
      results.keys.sort
    )
    assert_equal %i[revenue time_spent], results.uncovered.keys.sort
    assert results.uncovered[:time_spent].present?, "time_spent must carry a reason"
  end

  private

  LINK_ID = 555
  VISITOR_ID = 777

  def seed_pg_visitor(metrics)
    insert_pg_stat("visitor_daily_statistics", "visitor_id", VISITOR_ID, metrics)
  end

  def seed_pg_link(metrics)
    insert_pg_stat("link_daily_statistics", "link_id", LINK_ID, metrics)
  end

  # Raw insert bypasses belongs_to validations (the production path uses raw
  # upserts too); parity reads aggregate the rows, not the associations.
  def insert_pg_stat(table, key_col, key_val, metrics)
    m = default_metrics.merge(metrics)
    cols = m.keys
    ActiveRecord::Base.connection.execute(
      ActiveRecord::Base.sanitize_sql_array([
        "INSERT INTO #{table} (project_id, #{key_col}, event_date, platform, " \
        "#{cols.join(', ')}, created_at, updated_at) VALUES (?, ?, ?, ?, #{(['?'] * cols.size).join(', ')}, NOW(), NOW())",
        @project.id, key_val, @date, PLATFORM, *cols.map { |c| m[c] }
      ])
    )
  end

  def default_metrics
    { views: 0, opens: 0, installs: 0, reinstalls: 0, time_spent: 0,
      reactivations: 0, app_opens: 0, user_referred: 0 }
  end

  def seed_ch_visitor(metrics)
    seed_ch("visitor_metrics_daily", metrics.merge(visitor_id: VISITOR_ID))
  end

  def seed_ch_link(metrics)
    seed_ch("link_metrics_daily", metrics.merge(link_id: LINK_ID))
  end

  def seed_ch_link_daily(counts)
    rows = counts.map do |event_type, cnt|
      { project_id: @project.id, link_id: LINK_ID, campaign_id: 0, event_date: @date.to_s,
        event_type: event_type, platform: PLATFORM, cnt: cnt, total_engagement_time: 0 }
    end
    Clickhouse.with { |conn| conn.insert("link_daily", rows) }
  end

  def seed_ch(table, metrics)
    row = default_metrics.merge(metrics).merge(
      project_id: @project.id, event_date: @date.to_s, platform: PLATFORM
    )
    Clickhouse.with { |conn| conn.insert(table, [row]) }
  end
end
