# frozen_string_literal: true

require 'test_helper'

class Analytics::KeyMetricSeriesTest < ActiveSupport::TestCase
  include ClickhouseTestHelper

  fixtures :projects, :instances

  setup do
    skip_unless_clickhouse!
    @ch_auto_rebuild_breakdowns = true
    @project = projects(:one)
    @today = Date.current
  end

  teardown { Rails.cache.clear }

  test 'daily link_views series counts only link-attributed views and zero-fills days' do
    insert_ch_events([
      view_row('se_v1', link_id: 501, at: @today - 2),
      view_row('se_v2', link_id: 502, at: @today - 2),
      view_row('se_v3', link_id: 0, at: @today - 2),
      view_row('se_v4', link_id: 501, at: @today),
      view_row('se_foreign', link_id: 501, at: @today, project_id: 99_999)
    ])

    result = call_series(metric: 'link_views', start_date: @today - 3, end_date: @today)

    assert_equal 'link_views', result[:metric]
    assert_equal [0, 2, 0, 1], result[:points].map { |p| p[:value] }
    assert_equal ((@today - 3)..@today).map(&:to_s), result[:points].map { |p| p[:date] }
  end

  test 'views series counts all views including organic' do
    insert_ch_events([
      view_row('se_v5', link_id: 501, at: @today),
      view_row('se_v6', link_id: 0, at: @today)
    ])

    result = call_series(metric: 'views', start_date: @today, end_date: @today)

    assert_equal [2], result[:points].map { |p| p[:value] }
  end

  test 'organic_installs series subtracts link-driven from installs per day' do
    insert_ch_events([
      { event_id: 'se_i1', project_id: @project.id, event_type: Grovs::Events::INSTALL, link_id: 501,
        visitor_id: 32_001, created_at: ch_ts(@today) },
      { event_id: 'se_i2', project_id: @project.id, event_type: Grovs::Events::INSTALL, link_id: 0,
        visitor_id: 32_002, created_at: ch_ts(@today) }
    ])

    result = call_series(metric: 'organic_installs', start_date: @today, end_date: @today)

    assert_equal [1], result[:points].map { |p| p[:value] }
  end

  test 'platform filter scopes the series' do
    insert_ch_events([
      view_row('se_p1', link_id: 501, at: @today, platform: 'ios'),
      view_row('se_p2', link_id: 501, at: @today, platform: 'android')
    ])

    result = call_series(metric: 'link_views', start_date: @today, end_date: @today, platform: 'ios')

    assert_equal [1], result[:points].map { |p| p[:value] }
  end

  test 'unknown metric returns empty points without querying' do
    result = call_series(metric: 'password_hash', start_date: @today, end_date: @today)

    assert_equal [], result[:points]
  end

  test 'revenue series sums daily project metric cents per day and zero-fills' do
    DailyProjectMetric.where(project_id: @project.id).delete_all
    DailyProjectMetric.create!(project_id: @project.id, event_date: @today - 2, platform: 'ios', revenue: 1500)
    DailyProjectMetric.create!(project_id: @project.id, event_date: @today - 2, platform: 'android', revenue: 500)
    DailyProjectMetric.create!(project_id: @project.id, event_date: @today, platform: 'ios', revenue: 700)
    DailyProjectMetric.create!(project_id: projects(:two).id, event_date: @today, platform: 'ios', revenue: 9999)

    result = call_series(metric: 'revenue', start_date: @today - 3, end_date: @today)

    assert_equal 'revenue', result[:metric]
    assert_equal [0, 2000, 0, 700], result[:points].map { |p| p[:value] }
    assert_equal ((@today - 3)..@today).map(&:to_s), result[:points].map { |p| p[:date] }
  end

  test 'revenue series serves the previous range for compare and respects platform' do
    DailyProjectMetric.where(project_id: @project.id).delete_all
    DailyProjectMetric.create!(project_id: @project.id, event_date: @today - 3, platform: 'ios', revenue: 400)
    DailyProjectMetric.create!(project_id: @project.id, event_date: @today - 3, platform: 'android', revenue: 100)
    DailyProjectMetric.create!(project_id: @project.id, event_date: @today, platform: 'ios', revenue: 900)

    current = call_series(metric: 'revenue', start_date: @today - 1, end_date: @today)
    previous = call_series(metric: 'revenue', start_date: @today - 3, end_date: @today - 2)
    ios_previous = call_series(metric: 'revenue', start_date: @today - 3, end_date: @today - 2, platform: 'ios')

    assert_equal [0, 900], current[:points].map { |p| p[:value] }
    assert_equal [500, 0], previous[:points].map { |p| p[:value] }
    assert_equal [400, 0], ios_previous[:points].map { |p| p[:value] }
  end

  test 'revenue series buckets by week' do
    DailyProjectMetric.where(project_id: @project.id).delete_all
    DailyProjectMetric.create!(project_id: @project.id, event_date: @today - 10, platform: 'ios', revenue: 300)
    DailyProjectMetric.create!(project_id: @project.id, event_date: @today - 1, platform: 'ios', revenue: 200)
    DailyProjectMetric.create!(project_id: @project.id, event_date: @today, platform: 'ios', revenue: 100)

    points = Analytics::OverviewStatsService.key_metric_series(
      @project.id, metric: 'revenue', start_date: @today - 13, end_date: @today, granularity: 'week'
    )[:points]

    assert_equal [300, 300], points.map { |p| p[:value] }
  end

  test 'revenue series reads the ledger when flagged' do
    Rails.application.config.revenue_reads_from_ledger = true
    ledger = { @today => 1234 }

    result = RevenueLedgerQuery.stub(:daily_series, ledger) do
      call_series(metric: 'revenue', start_date: @today - 1, end_date: @today)
    end

    assert_equal [0, 1234], result[:points].map { |p| p[:value] }
  end

  test 'revenue series is flagged unsupported with no points under non-platform filters' do
    DailyProjectMetric.where(project_id: @project.id).delete_all
    DailyProjectMetric.create!(project_id: @project.id, event_date: @today, platform: 'ios', revenue: 700)

    result = Analytics::OverviewStatsService.key_metric_series(
      @project.id, metric: 'revenue', start_date: @today, end_date: @today,
                   filters: '[{"field":"country","operator":"is","value":"RO"}]'
    )

    assert_equal({ metric: 'revenue', points: [], unsupported: true }, result)
  end

  private

  def call_series(metric:, start_date:, end_date:, platform: nil)
    Analytics::OverviewStatsService.key_metric_series(
      @project.id, metric: metric, start_date: start_date, end_date: end_date, platform: platform
    )
  end

  def ch_ts(date)
    "#{date} 12:00:00.000"
  end

  def view_row(event_id, link_id:, at:, platform: 'ios', project_id: @project.id)
    { event_id: event_id, project_id: project_id, event_type: Grovs::Events::VIEW, link_id: link_id,
      visitor_id: 32_000, platform: platform, created_at: ch_ts(at) }
  end
end
