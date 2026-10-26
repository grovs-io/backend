# frozen_string_literal: true

require 'test_helper'

class Analytics::MetricQueryUniqueTotalsTest < ActiveSupport::TestCase
  include ClickhouseTestHelper

  fixtures :projects, :instances

  RAW = '[{"field":"os","operator":"is_not","value":"__none__"}]'

  setup do
    skip_unless_clickhouse!
    @ch_auto_rebuild_breakdowns = true
    @project = projects(:one)
    @seq = 0
  end

  teardown { Rails.cache.clear }

  def ev(visitor, days_ago, device: visitor, **attrs)
    @seq += 1
    { event_id: "uq_#{@seq}", project_id: @project.id, event_type: Grovs::Events::APP_OPEN, link_id: 0,
      visitor_id: visitor, device_id: device, platform: 'ios',
      created_at: ((Date.current - days_ago).to_time(:utc) + 12.hours).strftime('%Y-%m-%d %H:%M:%S.%3N') }.merge(attrs)
  end

  def run_query(raw: false, **params)
    params[:filters] = RAW if raw
    q = Analytics::MetricQuery.build(ActionController::Parameters.new(params), start_date: Date.current - 13, end_date: Date.current)
    assert_equal raw, q.raw?, "expected #{raw ? 'raw' : 'rollup'} path for #{params}"
    Analytics::MetricQueryService.run(@project.id, q)
  end

  def by_key(result, field = :value)
    result[:rows].to_h { |r| [r[:key], r[field]] }
  end

  test 'a visitor seen on two platforms is one visitor in the total, not the sum of rows' do
    insert_ch_events([ev(1, 1), ev(1, 1, platform: 'android'), ev(2, 2)])
    [false, true].each do |raw|
      r = run_query(raw: raw, metric: 'unique_visitors', group_by: 'platform')
      assert_equal({ 'ios' => 2, 'android' => 1 }, by_key(r), "raw=#{raw}")
      assert_equal 2, r[:total][:value], "raw=#{raw}: rows sum to 3 but only visitors 1 and 2 exist"
    end
  end

  test 'a device seen on two platforms is one device in the total' do
    insert_ch_events([ev(11, 1, device: 7), ev(12, 1, device: 7, platform: 'android'), ev(13, 1, device: 8)])
    [false, true].each do |raw|
      r = run_query(raw: raw, metric: 'unique_devices', group_by: 'platform')
      assert_equal({ 'ios' => 2, 'android' => 1 }, by_key(r), "raw=#{raw}")
      assert_equal 2, r[:total][:value], "raw=#{raw}"
    end
  end

  test 'the other bucket and the total dedup a visitor spread across many keys' do
    insert_ch_events([
      ev(1, 1, country: 'RO'), ev(2, 1, country: 'RO'), ev(4, 1, country: 'RO'),
      ev(1, 1, country: 'DE'), ev(3, 1, country: 'DE'), ev(1, 1, country: 'FR')
    ])
    [false, true].each do |raw|
      r = run_query(raw: raw, metric: 'unique_visitors', group_by: 'country', limit: '1')
      assert_equal({ 'RO' => 3 }, by_key(r), "raw=#{raw}")
      assert_equal 2, r[:other][:value], "raw=#{raw}: DE+FR hold visitors 1 and 3 only"
      assert_equal 4, r[:total][:value], "raw=#{raw}: rows+other is 5, distinct visitors are 4"
    end
  end

  test 'unique_devices by country has no rollup, so it reads raw events and stays exact' do
    insert_ch_events([ev(1, 1, country: 'RO'), ev(1, 1, country: 'DE'), ev(2, 1, country: 'DE')])
    q = Analytics::MetricQuery.build(ActionController::Parameters.new(metric: 'unique_devices', group_by: 'country'),
                                     start_date: Date.current - 13, end_date: Date.current)
    assert q.raw?
    r = Analytics::MetricQueryService.run(@project.id, q)
    assert_equal({ 'DE' => 2, 'RO' => 1 }, by_key(r))
    assert_equal %w[DE RO], r[:rows].map { |x| x[:key] }
    assert_equal 2, r[:total][:value]
  end

  test 'compare reports the exact previous unique total, not the sum of previous buckets' do
    insert_ch_events([
      ev(1, 1, country: 'RO'), ev(1, 1, country: 'DE'),
      ev(5, 20, country: 'RO'), ev(5, 20, country: 'DE'), ev(6, 20, country: 'RO')
    ])
    [false, true].each do |raw|
      r = run_query(raw: raw, metric: 'unique_visitors', group_by: 'country', compare: 'true')
      assert_equal({ 'DE' => 1, 'RO' => 1 }, by_key(r), "raw=#{raw}")
      assert_equal({ 'DE' => 1, 'RO' => 2 }, by_key(r, :previous), "raw=#{raw}")
      assert_equal({ value: 1, previous: 2 }, r[:total], "raw=#{raw}: previous buckets sum to 3, visitors 5 and 6 are 2")

      all = run_query(raw: raw, metric: 'unique_visitors', compare: 'true')
      assert_equal({ value: 1, previous: 2 }, all[:total], "raw=#{raw}: ungrouped")
      assert_equal 2, all[:rows][0][:previous]
    end
  end

  test 'compare: the previous unique total stays exact when every previous key falls into other' do
    insert_ch_events([ev(1, 1, country: 'RO'), ev(7, 20, country: 'DE'), ev(7, 20, country: 'FR')])
    r = run_query(raw: true, metric: 'unique_visitors', group_by: 'country', compare: 'true')
    assert_equal 0, r[:rows][0][:previous]
    assert_equal({ value: 1, previous: 1 }, r[:total])
    assert_equal 1, r[:other][:previous], 'DE and FR are one visitor in previous other'
    assert_equal 0, r[:other][:value]
  end

  test 'weekly uniques: points count per window, the row and total dedup across windows' do
    insert_ch_events([ev(1, 8), ev(1, 1, platform: 'android'), ev(1, 1), ev(2, 1)])
    [false, true].each do |raw|
      r = run_query(raw: raw, metric: 'unique_visitors', group_by: 'platform', granularity: 'week')
      assert_equal({ 'ios' => 2, 'android' => 1 }, by_key(r), "raw=#{raw}")
      assert_equal [1, 2], r[:rows].find { |x| x[:key] == 'ios' }[:points].map { |p| p[:value] }, "raw=#{raw}"
      assert_equal [0, 1], r[:rows].find { |x| x[:key] == 'android' }[:points].map { |p| p[:value] }, "raw=#{raw}"
      assert_equal 2, r[:total][:value], "raw=#{raw}: ios points sum to 3, android 1, visitors are 2"
    end
  end
end
