# frozen_string_literal: true

require 'test_helper'

class Analytics::TimeBucketsTest < ActiveSupport::TestCase
  test 'day windows are one per date' do
    w = Analytics::TimeBuckets.windows(Date.new(2026, 9, 1), Date.new(2026, 9, 3), 'day')
    assert_equal [[Date.new(2026, 9, 1), Date.new(2026, 9, 1)],
                  [Date.new(2026, 9, 2), Date.new(2026, 9, 2)],
                  [Date.new(2026, 9, 3), Date.new(2026, 9, 3)]], w
  end

  test 'week windows are consecutive 7-day spans from start_date, last one clipped' do
    w = Analytics::TimeBuckets.windows(Date.new(2026, 9, 3), Date.new(2026, 9, 20), 'week')
    assert_equal [[Date.new(2026, 9, 3), Date.new(2026, 9, 9)],
                  [Date.new(2026, 9, 10), Date.new(2026, 9, 16)],
                  [Date.new(2026, 9, 17), Date.new(2026, 9, 20)]], w
  end

  test 'month windows step by calendar month from start_date' do
    w = Analytics::TimeBuckets.windows(Date.new(2026, 1, 15), Date.new(2026, 3, 31), 'month')
    assert_equal [[Date.new(2026, 1, 15), Date.new(2026, 2, 14)],
                  [Date.new(2026, 2, 15), Date.new(2026, 3, 14)],
                  [Date.new(2026, 3, 15), Date.new(2026, 3, 31)]], w
  end

  test 'equal-length ranges yield equal bucket counts (previous-period alignment)' do
    cur = Analytics::TimeBuckets.windows(Date.new(2026, 9, 1), Date.new(2026, 9, 30), 'week')
    prev = Analytics::TimeBuckets.windows(Date.new(2026, 8, 2), Date.new(2026, 8, 31), 'week')
    assert_equal cur.size, prev.size
  end

  test 'accepts YYYY-MM-DD strings' do
    w = Analytics::TimeBuckets.windows('2026-09-01', '2026-09-02', 'day')
    assert_equal 2, w.size
  end

  test 'empty when start is after end' do
    assert_equal [], Analytics::TimeBuckets.windows(Date.new(2026, 9, 2), Date.new(2026, 9, 1), 'week')
  end

  test 'sum_by_window zero-fills and sums the days inside each window' do
    windows = Analytics::TimeBuckets.windows(Date.new(2026, 9, 1), Date.new(2026, 9, 14), 'week')
    points = Analytics::TimeBuckets.sum_by_window(
      { '2026-09-01' => 2, '2026-09-07' => 3, '2026-09-08' => 5 }, windows
    )
    assert_equal [{ date: '2026-09-01', value: 5 }, { date: '2026-09-08', value: 5 }], points
  end

  test 'month windows re-anchor to the start day after a short month' do
    w = Analytics::TimeBuckets.windows(Date.new(2026, 1, 31), Date.new(2026, 5, 31), 'month')
    assert_equal [[Date.new(2026, 1, 31), Date.new(2026, 2, 27)],
                  [Date.new(2026, 2, 28), Date.new(2026, 3, 30)],
                  [Date.new(2026, 3, 31), Date.new(2026, 4, 29)],
                  [Date.new(2026, 4, 30), Date.new(2026, 5, 30)],
                  [Date.new(2026, 5, 31), Date.new(2026, 5, 31)]], w
  end
end
