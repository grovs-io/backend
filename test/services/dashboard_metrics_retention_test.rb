# frozen_string_literal: true

require 'test_helper'

# The comparison period is a second read the controller-level gate never inspects.
class DashboardMetricsRetentionTest < ActiveSupport::TestCase
  fixtures :instances, :users, :instance_roles, :projects, :stripe_subscriptions, :stripe_payment_intents

  setup do
    @instance = instances(:two)
    @instance.update!(cold_storage_days: 365, delete_days: 365)
    @project = projects(:two)
    Rails.cache.clear
  end

  test 'the comparison period never reads below the cutoff' do
    ranges = capture_ranges { call_metrics(start_time: cutoff, end_time: cutoff + 90) }

    assert ranges.all? { |from, _to| from >= cutoff },
           "read below cutoff #{cutoff}: #{ranges.inspect}"
  end

  test 'a comparison period below the cutoff is zeroed rather than queried' do
    result = nil
    ranges = capture_ranges { result = call_metrics(start_time: cutoff, end_time: cutoff + 90) }

    assert_equal 1, ranges.size, 'only the current period should be read'
    assert_equal 0, result[:previous][:link_views]
    assert_equal 0.0, result[:previous][:returning_rate]
  end

  test 'a comparison period inside the window is still queried' do
    start_time = cutoff + 200
    ranges = capture_ranges { call_metrics(start_time: start_time, end_time: start_time + 10) }

    assert_equal 2, ranges.size, 'current and previous should both be read'
  end

  test 'the previous period keeps every key of the current one' do
    result = call_metrics(start_time: cutoff, end_time: cutoff + 90)

    assert_equal result[:current].keys.sort, result[:previous].keys.sort
  end

  # Straddle: the comparison window starts below the cutoff but ends above it.
  test 'a comparison period straddling the cutoff is flagged unavailable, not reported as zero growth' do
    start_time = cutoff + 30
    result = nil
    ranges = capture_ranges { result = call_metrics(start_time: start_time, end_time: start_time + 90) }

    assert_equal 1, ranges.size, 'the straddling comparison must not be queried'
    assert_not result[:previous_available], 'a zeroed comparison must be flagged'
  end

  test 'a comparison period fully inside the window is marked available' do
    start_time = cutoff + 200

    assert call_metrics(start_time: start_time, end_time: start_time + 10)[:previous_available]
  end

  test 'a comparison period fully outside the window is flagged unavailable' do
    assert_not call_metrics(start_time: cutoff, end_time: cutoff + 90)[:previous_available]
  end

  private

  def cutoff
    @cutoff ||= Date.current - @instance.cold_storage_days
  end

  def call_metrics(start_time:, end_time:)
    Clickhouse.stub(:analytics_rollups_read_enabled?, true) do
      DashboardMetrics.call(project_id: @project.id, start_time: start_time, end_time: end_time)
    end
  end

  def capture_ranges(&block)
    ranges = []
    recorder = lambda do |_project_id, start_date:, end_date:, **_rest|
      ranges << [start_date, end_date]
      0
    end

    ClickhouseReadService.stub(:link_views_total, recorder, &block)
    ranges
  end
end
