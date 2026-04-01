require "test_helper"

class DailyProjectMetricTest < ActiveSupport::TestCase
  fixtures :daily_project_metrics

  # === self.increment! ===

  test "increment! creates a new record when none exists" do
    # Use a raw project_id that does not conflict with fixtures
    raw_project_id = 999902
    new_date = Date.parse("2026-04-01")

    assert_difference "DailyProjectMetric.count", 1 do
      DailyProjectMetric.increment!(raw_project_id, "android", new_date, revenue: 500, units_sold: 2, cancellations: 0)
    end

    metric = DailyProjectMetric.find_by(project_id: raw_project_id, event_date: new_date, platform: "android")
    assert_not_nil metric
    assert_equal 500, metric.revenue
    assert_equal 2, metric.units_sold
    assert_equal 0, metric.cancellations
  end

  test "increment! increments existing record on conflict" do
    existing = daily_project_metrics(:metric_day1)
    raw_project_id = existing.project_id
    event_date = existing.event_date
    platform = existing.platform

    original_revenue = existing.revenue
    original_units = existing.units_sold
    original_cancellations = existing.cancellations

    assert_no_difference "DailyProjectMetric.count" do
      DailyProjectMetric.increment!(raw_project_id, platform, event_date, revenue: 100, units_sold: 1, cancellations: 1)
    end

    existing.reload
    assert_equal original_revenue + 100, existing.revenue
    assert_equal original_units + 1, existing.units_sold
    assert_equal original_cancellations + 1, existing.cancellations
  end

  test "increment! called twice increments cumulatively" do
    raw_project_id = 999903
    date = Date.parse("2026-05-01")

    DailyProjectMetric.increment!(raw_project_id, "web", date, revenue: 100, units_sold: 1, cancellations: 0)
    DailyProjectMetric.increment!(raw_project_id, "web", date, revenue: 200, units_sold: 3, cancellations: 1)

    metric = DailyProjectMetric.find_by(project_id: raw_project_id, event_date: date, platform: "web")
    assert_equal 300, metric.revenue
    assert_equal 4, metric.units_sold
    assert_equal 1, metric.cancellations
  end

  test "increment! with zero values does not change existing" do
    existing = daily_project_metrics(:metric_day1)
    raw_project_id = existing.project_id

    original_revenue = existing.revenue
    original_units = existing.units_sold

    DailyProjectMetric.increment!(raw_project_id, existing.platform, existing.event_date, revenue: 0, units_sold: 0, cancellations: 0)

    existing.reload
    assert_equal original_revenue, existing.revenue
    assert_equal original_units, existing.units_sold
  end

  test "increment! handles different platforms as separate records" do
    raw_project_id = 999904
    date = Date.parse("2026-06-01")

    DailyProjectMetric.increment!(raw_project_id, "ios", date, revenue: 100)
    DailyProjectMetric.increment!(raw_project_id, "android", date, revenue: 200)

    ios_metric = DailyProjectMetric.find_by(project_id: raw_project_id, event_date: date, platform: "ios")
    android_metric = DailyProjectMetric.find_by(project_id: raw_project_id, event_date: date, platform: "android")

    assert_equal 100, ios_metric.revenue
    assert_equal 200, android_metric.revenue
  end
end
