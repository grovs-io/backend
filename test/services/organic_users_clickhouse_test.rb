# frozen_string_literal: true

require "test_helper"

class OrganicUsersClickhouseTest < ActiveSupport::TestCase
  include ClickhouseTestHelper

  fixtures :projects, :instances, :devices, :visitors

  setup do
    skip_unless_clickhouse!
    truncate_clickhouse_tables
    @project = projects(:one)
    @pid = @project.id

    VisitorDailyStatistic.where(project_id: @pid).delete_all
    PurchaseEvent.where(project_id: @pid).delete_all

    @original_read = Rails.application.config.clickhouse_read_enabled
    @original_rollups = Rails.application.config.clickhouse_analytics_rollups_read_enabled
    Rails.application.config.clickhouse_read_enabled = true
    Rails.application.config.clickhouse_analytics_rollups_read_enabled = true
  end

  teardown do
    Rails.application.config.clickhouse_read_enabled = @original_read
    Rails.application.config.clickhouse_analytics_rollups_read_enabled = @original_rollups
  end

  test "underflow day contributes zero, not a wrapped UInt64, and is not netted" do
    # Day 1: link installs (5) exceed visitor installs (1) → clamp to 0
    # Day 2: 2 organic. Total must be 2 — not 0 (range netting), not ~1.8e19 (wrap).
    insert_visitor_rows([
      visitor_row(1, "2026-03-01", installs: 1),
      visitor_row(2, "2026-03-02", installs: 2)
    ])
    insert_link_rows([link_row(10, "2026-03-01", installs: 5)])

    total = organic(Date.new(2026, 3, 1), Date.new(2026, 3, 2))

    assert_equal 2, total
  end

  test "clamp happens per day, not after range aggregation" do
    # day1: 3-1=2, day2: max(1-4,0)=0 → 2. Range-aggregated would be max(4-5,0)=0.
    insert_visitor_rows([
      visitor_row(1, "2026-04-01", installs: 3),
      visitor_row(2, "2026-04-02", installs: 1)
    ])
    insert_link_rows([
      link_row(10, "2026-04-01", installs: 1),
      link_row(10, "2026-04-02", installs: 4)
    ])

    assert_equal 2, organic(Date.new(2026, 4, 1), Date.new(2026, 4, 2))
  end

  test "visitor-side installs include reinstalls; link side counts installs only" do
    # PG formula: (installs + reinstalls) - link_installs = (1+2) - 1 = 2.
    # The link row's reinstalls must NOT be subtracted.
    insert_visitor_rows([visitor_row(1, "2026-05-01", installs: 1, reinstalls: 2)])
    insert_link_rows([link_row(10, "2026-05-01", installs: 1, reinstalls: 9)])

    assert_equal 2, organic(Date.new(2026, 5, 1), Date.new(2026, 5, 1))
  end

  test "visitor metrics with no link metrics are fully organic" do
    insert_visitor_rows([visitor_row(1, "2026-06-01", installs: 3, reinstalls: 1)])

    assert_equal 4, organic(Date.new(2026, 6, 1), Date.new(2026, 6, 1))
  end

  test "link metrics with no visitor metrics contribute zero" do
    insert_link_rows([link_row(10, "2026-07-01", installs: 6)])

    assert_equal 0, organic(Date.new(2026, 7, 1), Date.new(2026, 7, 1))
  end

  test "raw mac visitor rows and web link rows land in the same normalized bucket" do
    # Without normalization these split into 'mac' and 'web' buckets → 2 organic.
    # Normalized they join: (2+0) - 1 = 1.
    insert_visitor_rows([visitor_row(1, "2026-08-01", installs: 2, platform: "mac")])
    insert_link_rows([link_row(10, "2026-08-01", installs: 1, platform: "web")])

    assert_equal 1, organic(Date.new(2026, 8, 1), Date.new(2026, 8, 1))
  end

  test "platform filter restricts both sides through normalization" do
    insert_visitor_rows([
      visitor_row(1, "2026-09-01", installs: 2, platform: "mac"),
      visitor_row(2, "2026-09-01", installs: 5, platform: "ios")
    ])
    insert_link_rows([link_row(10, "2026-09-01", installs: 1, platform: "web")])

    assert_equal 1, organic(Date.new(2026, 9, 1), Date.new(2026, 9, 1), platform: "web")
    assert_equal 5, organic(Date.new(2026, 9, 1), Date.new(2026, 9, 1), platform: "ios")
  end

  test "empty range returns zero, disabled reads return nil" do
    assert_equal 0, organic(Date.new(2027, 1, 1), Date.new(2027, 1, 1))

    Rails.application.config.clickhouse_read_enabled = false
    assert_nil organic(Date.new(2027, 1, 1), Date.new(2027, 1, 1))
  end

  test "dashboard serves CH organic when flag on, PG when reader returns nil" do
    insert_visitor_rows([visitor_row(1, "2026-10-01", installs: 3)])
    insert_link_rows([link_row(10, "2026-10-01", installs: 1)])
    DailyProjectMetric.create!(
      project_id: @pid, event_date: Date.new(2026, 10, 1), platform: "ios",
      views: 0, installs: 0, opens: 0, reinstalls: 0, link_views: 0,
      referred_users: 0, organic_users: 9, new_users: 0, app_opens: 0,
      first_time_visitors: 0, revenue: 0, units_sold: 0, cancellations: 0,
      first_time_purchases: 0
    )

    current = DashboardMetrics.call(
      project_id: @pid, start_time: Date.new(2026, 10, 1), end_time: Date.new(2026, 10, 1)
    )[:current]
    assert_equal 2, current[:organic_users]

    ClickhouseReadService.stub(:organic_users_total, nil) do
      fallback = DashboardMetrics.call(
        project_id: @pid, start_time: Date.new(2026, 10, 1), end_time: Date.new(2026, 10, 2)
      )[:current]
      assert_equal 9, fallback[:organic_users]
    end
  end

  test "rollup parity covers organic_users through the serving reader" do
    insert_visitor_rows([visitor_row(1, "2026-11-01", installs: 3)])
    insert_link_rows([link_row(10, "2026-11-01", installs: 1)])
    DailyProjectMetric.create!(
      project_id: @pid, event_date: Date.new(2026, 11, 1), platform: "ios",
      views: 0, installs: 0, opens: 0, reinstalls: 0, link_views: 0,
      referred_users: 0, organic_users: 2, new_users: 0, app_opens: 0,
      first_time_visitors: 0, revenue: 0, units_sold: 0, cancellations: 0,
      first_time_purchases: 0
    )

    report = Billing::ClickhouseParityCheck.rollup_parity(
      rollup: :project, project_id: @pid,
      start_date: Date.new(2026, 11, 1), end_date: Date.new(2026, 11, 1)
    )

    assert_not_includes report.uncovered.keys, :organic_users
    assert report.covered[:organic_users].match?,
           "organic parity: pg=#{report.covered[:organic_users].postgres_count} " \
           "ch=#{report.covered[:organic_users].clickhouse_count}"
  end

  # e070995: DPM is a stale snapshot, so the project-grain counters (and their
  # installs+reinstalls folding) are no longer graded — visitor grain covers them.
  test "project-grain installs and reinstalls are uncovered against stale DPM" do
    report = Billing::ClickhouseParityCheck.rollup_parity(
      rollup: :project, project_id: @pid,
      start_date: Date.new(2027, 3, 1), end_date: Date.new(2027, 3, 1)
    )

    assert_nil report.covered[:installs], "installs must NOT be silently covered"
    assert_nil report.covered[:reinstalls]
    assert report.uncovered[:installs].present?, "installs must carry an uncovered reason"
    assert report.uncovered[:reinstalls].present?
  end

  test "rollup parity catches per-day organic errors that cancel in the range total" do
    # PG: day1=2, day2=0; CH: day1=0, day2=2 — totals equal, days wrong
    insert_visitor_rows([visitor_row(1, "2027-04-02", installs: 2)])
    [[1, 2], [2, 0]].each do |day, organic|
      DailyProjectMetric.create!(
        project_id: @pid, event_date: Date.new(2027, 4, day), platform: "ios",
        views: 0, installs: 0, opens: 0, reinstalls: 0, link_views: 0,
        referred_users: 0, organic_users: organic, new_users: 0, app_opens: 0,
        first_time_visitors: 0, revenue: 0, units_sold: 0, cancellations: 0,
        first_time_purchases: 0
      )
    end

    report = Billing::ClickhouseParityCheck.rollup_parity(
      rollup: :project, project_id: @pid,
      start_date: Date.new(2027, 4, 1), end_date: Date.new(2027, 4, 2)
    )

    assert_not report.covered[:organic_users].match?
  end

  test "rollup parity flags an organic mismatch" do
    insert_visitor_rows([visitor_row(1, "2026-12-01", installs: 5)])
    DailyProjectMetric.create!(
      project_id: @pid, event_date: Date.new(2026, 12, 1), platform: "ios",
      views: 0, installs: 0, opens: 0, reinstalls: 0, link_views: 0,
      referred_users: 0, organic_users: 3, new_users: 0, app_opens: 0,
      first_time_visitors: 0, revenue: 0, units_sold: 0, cancellations: 0,
      first_time_purchases: 0
    )

    report = Billing::ClickhouseParityCheck.rollup_parity(
      rollup: :project, project_id: @pid,
      start_date: Date.new(2026, 12, 1), end_date: Date.new(2026, 12, 1)
    )

    assert_not report.covered[:organic_users].match?
  end

  private

  def organic(start_date, end_date, platform: nil)
    ClickhouseReadService.organic_users_total(
      @pid, start_date: start_date, end_date: end_date, platform: platform
    )
  end

  def visitor_row(visitor_id, date, installs: 0, reinstalls: 0, platform: "ios")
    { project_id: @pid, visitor_id: visitor_id, event_date: date, platform: platform,
      views: 0, opens: 0, installs: installs, reinstalls: reinstalls, time_spent: 0,
      reactivations: 0, app_opens: 0, user_referred: 0, inviter_id: 0 }
  end

  def link_row(link_id, date, installs: 0, reinstalls: 0, platform: "ios")
    { project_id: @pid, link_id: link_id, event_date: date, platform: platform,
      views: 0, opens: 0, installs: installs, reinstalls: reinstalls, time_spent: 0,
      reactivations: 0, app_opens: 0, user_referred: 0 }
  end

  def insert_visitor_rows(rows)
    Clickhouse.with { |conn| conn.insert("visitor_metrics_daily", rows) }
  end

  def insert_link_rows(rows)
    Clickhouse.with { |conn| conn.insert("link_metrics_daily", rows) }
  end
end
