require "test_helper"

class DailyProjectMetricsGeneratorTest < ActiveSupport::TestCase
  fixtures :instances, :projects, :visitors, :devices, :visitor_daily_statistics,
           :link_daily_statistics, :links, :domains, :redirect_configs,
           :in_app_products, :in_app_product_daily_statistics

  setup do
    @project = projects(:one)
    # Fixtures have data on 2026-03-01 and 2026-03-02
    @date = Date.new(2026, 3, 1)
  end

  test "aggregates visitor stats into daily metric" do
    DailyProjectMetricsGenerator.call(@date)

    metric = DailyProjectMetric.find_by(project_id: @project.id, event_date: @date, platform: "ios")
    assert metric
    # ios_stat_day1: views=50, opens=20, installs=5, reinstalls=1
    assert_equal 50, metric.views
    assert_equal 20, metric.opens
    assert_equal 6, metric.installs # installs(5) + reinstalls(1)
  end

  test "aggregates link stats into daily metric" do
    DailyProjectMetricsGenerator.call(@date)

    metric = DailyProjectMetric.find_by(project_id: @project.id, event_date: @date, platform: "ios")
    assert metric
    # stat_day1: link=basic_link, views=100, installs=10, platform=ios
    assert_equal 100, metric.link_views
  end

  test "organic_users clamped at zero" do
    # Create a scenario where link_installs > total installs
    new_date = Date.new(2026, 6, 1)
    visitor = visitors(:ios_visitor)

    VisitorDailyStatistic.create!(
      visitor: visitor, project_id: @project.id, event_date: new_date,
      platform: Grovs::Platforms::IOS, views: 1, installs: 2
    )
    # Link stats showing more installs than visitors had
    LinkDailyStatService.bulk_upsert_link_stats([{
      project_id: @project.id, link_id: links(:basic_link).id,
      event_date: new_date, platform: Grovs::Platforms::IOS,
      metrics: { installs: 100 }
    }])

    DailyProjectMetricsGenerator.call(new_date)

    metric = DailyProjectMetric.find_by(project_id: @project.id, event_date: new_date, platform: Grovs::Platforms::IOS)
    assert_equal 0, metric.organic_users
  end

  test "returning users counted from earlier date" do
    # Fixtures: ios_visitor has ios_stat_day1 (2026-03-01) and ios_stat_day2 (2026-03-02)
    # On day2, ios_visitor existed on day1 → exactly 1 returning user
    day2 = Date.new(2026, 3, 2)
    DailyProjectMetricsGenerator.call(day2)

    metric = DailyProjectMetric.find_by(project_id: @project.id, event_date: day2, platform: "ios")
    assert metric
    assert_equal 1, metric.returning_users
  end

  test "first_time_visitors excludes earlier visitors" do
    # day1: ios_visitor has no prior records → exactly 1 first-time visitor
    DailyProjectMetricsGenerator.call(@date)

    metric_day1 = DailyProjectMetric.find_by(project_id: @project.id, event_date: @date, platform: "ios")
    assert_equal 1, metric_day1.first_time_visitors

    # day2: same ios_visitor already seen day1 → 0 first-time visitors
    day2 = Date.new(2026, 3, 2)
    DailyProjectMetricsGenerator.call(day2)

    metric_day2 = DailyProjectMetric.find_by(project_id: @project.id, event_date: day2, platform: "ios")
    assert_equal 0, metric_day2.first_time_visitors
  end

  test "new_users requires first_time and installs" do
    new_date = Date.new(2026, 6, 2)
    visitor = visitors(:ios_visitor)

    # First-time visitor with 0 installs → not a new user
    VisitorDailyStatistic.create!(
      visitor: visitor, project_id: @project.id, event_date: new_date,
      platform: Grovs::Platforms::IOS, views: 5, installs: 0
    )

    DailyProjectMetricsGenerator.call(new_date)

    metric = DailyProjectMetric.find_by(project_id: @project.id, event_date: new_date, platform: Grovs::Platforms::IOS)
    assert_equal 0, metric.new_users
  end

  test "referred_users counts non-nil invited_by" do
    new_date = Date.new(2026, 6, 3)
    visitor = visitors(:ios_visitor)
    referrer = visitors(:android_visitor)

    VisitorDailyStatistic.create!(
      visitor: visitor, project_id: @project.id, event_date: new_date,
      platform: Grovs::Platforms::IOS, views: 1, invited_by_id: referrer.id
    )

    DailyProjectMetricsGenerator.call(new_date)

    metric = DailyProjectMetric.find_by(project_id: @project.id, event_date: new_date, platform: Grovs::Platforms::IOS)
    assert_equal 1, metric.referred_users
  end

  test "upsert does not duplicate on re-run" do
    DailyProjectMetricsGenerator.call(@date)
    count_after_first = DailyProjectMetric.where(event_date: @date).count

    DailyProjectMetricsGenerator.call(@date)
    assert_equal count_after_first, DailyProjectMetric.where(event_date: @date).count
  end

  test "separates metrics by platform" do
    DailyProjectMetricsGenerator.call(@date)

    ios_metric = DailyProjectMetric.find_by(project_id: @project.id, event_date: @date, platform: "ios")
    android_metric = DailyProjectMetric.find_by(project_id: @project.id, event_date: @date, platform: "android")

    # ios_stat_day1: views=50; android_stat_day1: views=30
    assert ios_metric
    assert android_metric
    assert_equal 50, ios_metric.views
    assert_equal 30, android_metric.views
  end

  test "revenue from IAP stats" do
    DailyProjectMetricsGenerator.call(@date)

    metric = DailyProjectMetric.find_by(project_id: @project.id, event_date: @date, platform: "ios")
    assert metric
    # premium_day1: revenue=999, purchase_events=1
    assert_equal 999, metric.revenue
    assert_equal 1, metric.units_sold
  end
end
