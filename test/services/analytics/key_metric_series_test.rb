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
