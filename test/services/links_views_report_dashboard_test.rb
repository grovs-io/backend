require "test_helper"

class LinksViewsReportDashboardTest < ActiveSupport::TestCase
  fixtures :instances, :projects, :daily_project_metrics

  # Fixture metric_day1: project :one, event_date 2026-02-15, platform ios, link_views 80

  setup do
    @pid = projects(:one).id
  end

  test "zero-fills all dates when no data exists for project" do
    result = LinksViewsReportDashboard.new(
      project_id: 0, platform: nil,
      start_date: Date.new(2026, 3, 1), end_date: Date.new(2026, 3, 3)
    ).call

    assert_equal 3, result.size
    assert result.values.all?(&:zero?)
  end

  test "populates actual link_views from DailyProjectMetric" do
    result = LinksViewsReportDashboard.new(
      project_id: @pid, platform: nil,
      start_date: Date.new(2026, 2, 15), end_date: Date.new(2026, 2, 15)
    ).call

    # Service writes DB results with string key via date.to_s
    assert_equal 80, result[Date.new(2026, 2, 15).to_s]
  end

  test "filters by platform — no android data returns all zeros" do
    result = LinksViewsReportDashboard.new(
      project_id: @pid, platform: "android",
      start_date: Date.new(2026, 2, 15), end_date: Date.new(2026, 2, 15)
    ).call

    assert_equal 0, result[Date.new(2026, 2, 15)]
  end

  test "multi-day range with data on one day — other days stay zero" do
    # Add a second metric for 2026-02-16
    DailyProjectMetric.create!(
      project_id: @pid, event_date: "2026-02-16", platform: "ios",
      link_views: 45, views: 0, installs: 0, opens: 0, reinstalls: 0,
      returning_users: 0, referred_users: 0, organic_users: 0, new_users: 0,
      app_opens: 0, first_time_visitors: 0, revenue: 0, units_sold: 0,
      cancellations: 0, first_time_purchases: 0
    )

    result = LinksViewsReportDashboard.new(
      project_id: @pid, platform: nil,
      start_date: Date.new(2026, 2, 15), end_date: Date.new(2026, 2, 17)
    ).call

    assert_equal 80, result["2026-02-15"]
    assert_equal 45, result["2026-02-16"]
    # 2026-02-17 has no data, only the Date key exists with 0
    assert_equal 0, result[Date.new(2026, 2, 17)]
  end
end
