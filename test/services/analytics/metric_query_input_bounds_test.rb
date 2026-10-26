# frozen_string_literal: true

require 'test_helper'

class Analytics::MetricQueryInputBoundsTest < ActiveSupport::TestCase
  def build(params = {}, start_date: Date.new(2026, 9, 1), end_date: Date.new(2026, 9, 30), cutoff: nil, **rest)
    Analytics::MetricQuery.build(ActionController::Parameters.new({ metric: 'installs' }.merge(params).merge(rest)),
                                 start_date: start_date, end_date: end_date, cutoff: cutoff)
  end

  def invalid_message(params)
    assert_raises(Analytics::MetricQuery::Invalid) { build(params) }.message
  end

  test 'limit accepts exactly 1..50, defaults when blank and rejects non-integers' do
    assert_equal 1, build(limit: '1').limit
    assert_equal 50, build(limit: '50').limit
    assert_equal 10, build(limit: '').limit
    %w[0 51 abc 2.5 -3].each do |bad|
      assert_equal 'limit must be between 1 and 50', invalid_message(limit: bad), bad
    end
  end

  test 'error messages name the allowed values, since the endpoint returns them verbatim' do
    assert_equal "metric must be one of #{Analytics::MetricQuery::METRICS.join(', ')}", invalid_message(metric: '')
    assert_equal 'unknown group_by', invalid_message(group_by: 'ip')
    assert_equal 'granularity must be day, week or month', invalid_message(granularity: 'year')
  end

  test 'properties. and user. keys must be non-empty and free of injection characters' do
    ['properties.', 'user.', 'user.bad`key', 'user.a b', "properties.x\\y", 'user.' + ('k' * 257)].each do |dim|
      assert_equal 'unknown group_by', invalid_message(group_by: dim), dim
    end
    assert_equal 'user.k', build(group_by: 'user.k').group_by
  end

  test 'compare is on only for truthy values' do
    { 'true' => true, '1' => true, 'false' => false, '0' => false, '' => false }.each do |raw, expected|
      assert_equal expected, build(compare: raw).compare, raw.inspect
    end
  end

  test 'a one-day range compares against the single day before it' do
    q = build(start_date: Date.new(2026, 3, 1), end_date: Date.new(2026, 3, 1))
    assert_equal '2026-02-28', q.prev_start_day
    assert_equal '2026-02-28', q.prev_end_day
  end

  test 'a cutoff older than the previous period does not shift it' do
    q = build(cutoff: Date.new(2026, 1, 1))
    assert_equal '2026-08-02', q.prev_start_day
  end

  test 'cache key separates metric, filters, dates and cutoff so a cached answer never crosses queries' do
    base = build.cache_key
    assert_not_equal base, build(metric: 'opens').cache_key
    assert_not_equal base, build(start_date: Date.new(2026, 9, 2)).cache_key
    assert_not_equal base, build(end_date: Date.new(2026, 9, 29)).cache_key
    ro = build(filters: '[{"field":"country","operator":"is","value":"RO"}]').cache_key
    de = build(filters: '[{"field":"country","operator":"is","value":"DE"}]').cache_key
    assert_not_equal base, ro
    assert_not_equal ro, de
    assert_equal ro, build(filters: '[{"field":"country","operator":"is","value":"RO"}]').cache_key
  end
end
