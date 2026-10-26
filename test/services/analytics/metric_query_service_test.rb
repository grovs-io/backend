# frozen_string_literal: true

require 'test_helper'

class Analytics::MetricQueryServiceTest < ActiveSupport::TestCase
  include ClickhouseTestHelper

  fixtures :projects, :instances, :domains, :links, :campaigns

  setup do
    skip_unless_clickhouse!
    @ch_auto_rebuild_breakdowns = true
    @project = projects(:one)
    @now = Time.current
  end

  teardown { Rails.cache.clear }

  def at_noon(days_ago)
    ((Date.current - days_ago).to_time(:utc) + 12.hours).strftime('%Y-%m-%d %H:%M:%S.%3N')
  end

  def install(id, visitor, days_ago, **attrs)
    { event_id: "mq_#{id}", project_id: @project.id, event_type: Grovs::Events::INSTALL, link_id: 0,
      visitor_id: visitor, platform: 'ios', created_at: at_noon(days_ago) }.merge(attrs)
  end

  # Ruby 3 routes literal `key: value` args to declared keywords (see metric_query_test.rb).
  def query(overrides = {}, **kwargs)
    start_date = kwargs.delete(:start_date) || Date.current - 13
    end_date = kwargs.delete(:end_date) || Date.current
    platform = kwargs.delete(:platform)
    params = ActionController::Parameters.new({ metric: 'installs' }.merge(overrides).merge(kwargs))
    Analytics::MetricQuery.build(params, start_date: start_date, end_date: end_date, platform: platform)
  end

  # Non-platform filter forces the raw path in every test below.
  RAW = '[{"field":"os","operator":"is_not","value":"__none__"}]'

  test 'raw: groups by country with top-N and other' do
    insert_ch_events([
      install(1, 1001, 1, country: 'RO'), install(2, 1002, 1, country: 'RO'), install(3, 1003, 1, country: 'RO'),
      install(4, 1004, 1, country: 'DE'), install(5, 1005, 1, country: 'DE'),
      install(6, 1006, 1, country: 'FR'), install(7, 1007, 1, country: 'IT')
    ])
    q = query(group_by: 'country', limit: '2', filters: RAW)
    assert q.raw?

    r = Analytics::MetricQueryService.run(@project.id, q)

    assert_equal %w[RO DE], r[:rows].map { |x| x[:key] }
    assert_equal [3, 2], r[:rows].map { |x| x[:value] }
    assert_equal 'RO', r[:rows][0][:label]
    assert_equal 2, r[:other][:value]
    assert_equal '__other__', r[:other][:key]
    assert_equal 7, r[:total][:value]
    assert_nil r[:rows][0][:points]
  end

  test 'raw: no group_by returns one "all" row and no other' do
    insert_ch_events([install(1, 1101, 1), install(2, 1102, 2)])
    r = Analytics::MetricQueryService.run(@project.id, query(filters: RAW))
    assert_equal 1, r[:rows].size
    assert_equal 'all', r[:rows][0][:key]
    assert_equal 2, r[:rows][0][:value]
    assert_nil r[:other]
    assert_equal 2, r[:total][:value]
  end

  test 'raw: week granularity yields range-relative zero-filled points per row' do
    insert_ch_events([install(1, 1201, 8, country: 'RO'), install(2, 1202, 1, country: 'RO'), install(3, 1203, 1, country: 'RO')])
    r = Analytics::MetricQueryService.run(@project.id, query(group_by: 'country', granularity: 'week', filters: RAW))
    row = r[:rows][0]
    assert_equal 'RO', row[:key]
    assert_equal 3, row[:value]
    assert_equal [{ date: (Date.current - 13).to_s, value: 1 }, { date: (Date.current - 6).to_s, value: 2 }], row[:points]
  end

  test 'raw: unique_visitors dedups within window and across the range' do
    insert_ch_events([
      install(1, 1301, 8, country: 'RO'), install(2, 1301, 1, country: 'RO'), install(3, 1302, 1, country: 'RO')
    ])
    r = Analytics::MetricQueryService.run(@project.id, query(metric: 'unique_visitors', group_by: 'country', granularity: 'week', filters: RAW))
    row = r[:rows][0]
    assert_equal 2, row[:value], 'visitor 1301 appears in both weeks but counts once for the range'
    assert_equal [1, 2], row[:points].map { |p| p[:value] }
    assert_equal 2, r[:total][:value]
  end

  test 'raw: compare returns previous-period values for the same keys' do
    insert_ch_events([
      install(1, 1401, 1, country: 'RO'), install(2, 1402, 1, country: 'RO'),
      install(3, 1403, 20, country: 'RO'), install(4, 1404, 20, country: 'DE')
    ])
    r = Analytics::MetricQueryService.run(@project.id, query(group_by: 'country', compare: 'true', filters: RAW))
    ro = r[:rows].find { |x| x[:key] == 'RO' }
    assert_equal 2, ro[:value]
    assert_equal 1, ro[:previous]
    assert_equal 1, r[:other][:previous], 'DE is not in the current top-N, so it lands in other for the previous period'
    assert_equal 2, r[:total][:value]
    assert_equal 2, r[:total][:previous]
  end

  test 'raw: compare keeps the previous total when the current period is empty' do
    insert_ch_events([install(1, 1501, 20, country: 'RO'), install(2, 1502, 20, country: 'DE')])
    ungrouped = Analytics::MetricQueryService.run(@project.id, query(compare: 'true', filters: RAW))
    assert_equal({ value: 0, previous: 2 }, ungrouped[:total])
    grouped = Analytics::MetricQueryService.run(@project.id, query(group_by: 'country', compare: 'true', filters: RAW))
    assert_equal({ value: 0, previous: 2 }, grouped[:total])
  end

  test 'raw: link_id rows are labelled from Postgres and source rows from the taxonomy' do
    link = links(:basic_link)
    insert_ch_events([install(1, 1501, 1, link_id: link.id), install(2, 1502, 1, link_id: link.id, campaign_id: 42)])
    r = Analytics::MetricQueryService.run(@project.id, query(group_by: 'link_id', filters: RAW))
    assert_equal link.id.to_s, r[:rows][0][:key]
    assert_equal link.name, r[:rows][0][:label]

    s = Analytics::MetricQueryService.run(@project.id, query(group_by: 'source', filters: RAW))
    assert_equal %w[campaigns links].sort, s[:rows].map { |x| x[:key] }.sort
    assert_equal 'Campaigns', s[:rows].find { |x| x[:key] == 'campaigns' }[:label]
  end

  test 'raw: the no-link bucket is labelled (none) and keeps key 0' do
    insert_ch_events([install(1, 1801, 1, link_id: 0), install(2, 1802, 1, link_id: links(:basic_link).id)])
    r = Analytics::MetricQueryService.run(@project.id, query(group_by: 'link_id', filters: RAW))
    none = r[:rows].find { |x| x[:key] == '0' }
    assert_equal '(none)', none[:label]
    assert_equal 1, none[:value]
  end

  test 'raw: empty values are labelled (none)' do
    insert_ch_events([install(1, 1601, 1, country: '')])
    r = Analytics::MetricQueryService.run(@project.id, query(group_by: 'country', filters: RAW))
    assert_equal '', r[:rows][0][:key]
    assert_equal '(none)', r[:rows][0][:label]
  end

  test 'run caches by query cache_key' do
    with_memory_cache do
      insert_ch_events([install(1, 1701, 1)])
      q = query(filters: RAW)
      first = Analytics::MetricQueryService.run(@project.id, q)
      insert_ch_events([install(2, 1702, 1)])
      assert_equal first, Analytics::MetricQueryService.run(@project.id, q)
    end
  end

  test 'rollup: country breakdown matches the raw path' do
    insert_ch_events([
      install(1, 2001, 1, country: 'RO'), install(2, 2002, 1, country: 'RO'), install(3, 2003, 3, country: 'DE'),
      { event_id: 'mq_view', project_id: @project.id, event_type: Grovs::Events::VIEW, link_id: 0,
        visitor_id: 2004, platform: 'android', country: 'RO', created_at: at_noon(1) }
    ])
    rollup_q = query(group_by: 'country')
    raw_q = query(group_by: 'country', filters: RAW)
    assert_equal false, rollup_q.raw?
    assert rollup_q.plan(@project.id)[:from] == 'project_country_daily'

    rollup = Analytics::MetricQueryService.run(@project.id, rollup_q)
    raw = Analytics::MetricQueryService.run(@project.id, raw_q)

    assert_equal raw[:rows].map { |r| [r[:key], r[:value]] }, rollup[:rows].map { |r| [r[:key], r[:value]] }
    assert_equal 3, rollup[:total][:value]
  end

  test 'rollup: platform chip and platform group_by use project_daily and normalise web' do
    insert_ch_events([install(1, 2101, 1, platform: 'ios'), install(2, 2102, 1, platform: 'mac'), install(3, 2103, 1, platform: 'android')])
    r = Analytics::MetricQueryService.run(@project.id, query(group_by: 'platform'))
    assert_equal({ 'ios' => 1, 'web' => 1, 'android' => 1 }, r[:rows].to_h { |x| [x[:key], x[:value]] })

    ios = Analytics::MetricQueryService.run(@project.id, query(filters: '[{"field":"platform","operator":"is","value":"ios"}]'))
    assert_equal 1, ios[:total][:value]
  end

  test 'rollup: unique_visitors by app_version and source via untyped rollups' do
    insert_ch_events([
      install(1, 2201, 1, app_version: '1.0'), install(2, 2201, 2, app_version: '1.0'), install(3, 2202, 1, app_version: '2.0')
    ])
    v = Analytics::MetricQueryService.run(@project.id, query(metric: 'unique_visitors', group_by: 'app_version'))
    assert_equal({ '1.0' => 1, '2.0' => 1 }, v[:rows].to_h { |x| [x[:key], x[:value]] })
    s = Analytics::MetricQueryService.run(@project.id, query(metric: 'unique_visitors', group_by: 'source'))
    assert_equal 2, s[:rows].find { |x| x[:key] == 'organic' }[:value]
  end

  test 'rollup: week granularity points from event_date' do
    insert_ch_events([install(1, 2301, 8), install(2, 2302, 1)])
    r = Analytics::MetricQueryService.run(@project.id, query(granularity: 'week'))
    assert_equal [1, 1], r[:rows][0][:points].map { |p| p[:value] }
    assert_equal 2, r[:rows][0][:value]
  end

  test 'raw: events metric counts every event type, grouped by event_name' do
    insert_ch_events([
      install(1, 2401, 1, event_name: 'buy'),
      install(2, 2402, 1, event_name: 'buy', event_type: Grovs::Events::OPEN),
      install(3, 2403, 1, event_name: '')
    ])
    r = Analytics::MetricQueryService.run(@project.id, query(metric: 'events', group_by: 'event_name'))
    assert_equal 3, r[:total][:value]
    assert_equal 2, r[:rows].find { |x| x[:key] == 'buy' }[:value]
  end

  test 'raw: a platform-only request still filters raw reads by platform' do
    insert_ch_events([
      install(1, 2501, 1, city: 'Cluj'), install(2, 2502, 1, city: 'Cluj', platform: 'android'),
      install(3, 2503, 1, city: 'Iasi', platform: 'android')
    ])
    events = query(metric: 'events', platform: 'ios')
    assert events.raw?
    assert_equal 1, Analytics::MetricQueryService.run(@project.id, events)[:total][:value]

    by_city = Analytics::MetricQueryService.run(@project.id, query(group_by: 'city', platform: 'ios'))
    assert_equal({ 'Cluj' => 1 }, by_city[:rows].to_h { |x| [x[:key], x[:value]] })
  end

  test 'rollup: a desktop platform value reads the web bucket' do
    insert_ch_events([install(1, 2601, 1, platform: 'mac'), install(2, 2602, 1, platform: 'windows'), install(3, 2603, 1)])
    q = query(platform: 'mac')
    assert_equal false, q.raw?
    assert_equal 2, Analytics::MetricQueryService.run(@project.id, q)[:total][:value]
  end

  test 'parity: a merged visitor counts once and visitor/device 0 never count, on both paths' do
    alias_visitor(2701, 2702)
    insert_ch_events([
      install(1, 2701, 1, country: 'RO', device_id: 1), install(2, 2702, 2, country: 'RO', device_id: 1),
      install(3, 0, 1, country: 'RO', device_id: 0), install(4, 2703, 1, country: 'DE', device_id: 2)
    ])
    %w[unique_visitors unique_devices].each do |metric|
      group_by = metric == 'unique_visitors' ? 'country' : 'platform'
      rollup, raw = both_paths(metric: metric, group_by: group_by)
      assert_equal raw, rollup, metric
    end
    rollup, = both_paths(metric: 'unique_visitors', group_by: 'country')
    assert_equal({ rows: { 'RO' => 1, 'DE' => 1 }, total: 2 }, rollup)
    rollup, = both_paths(metric: 'unique_devices', group_by: 'platform')
    assert_equal({ rows: { 'ios' => 2 }, total: 2 }, rollup)
  end

  test 'parity: message events are not activity on either path' do
    insert_ch_events([
      install(1, 2801, 1, device_id: 11),
      install(2, 2802, 1, device_id: 12, event_type: 'custom', event_name: Grovs::Events::PUSH_OPEN),
      install(3, 2803, 1, device_id: 13, event_type: 'custom', event_name: 'in_app_viewed'),
      install(4, 2804, 1, device_id: 14, event_type: 'custom', event_name: 'checkout')
    ])
    %w[unique_visitors unique_devices].each do |metric|
      rollup, raw = both_paths(metric: metric)
      assert_equal raw, rollup, metric
      assert_equal 2, rollup[:total], "#{metric}: the install and the real custom event only"
    end
  end

  test 'parity: purchase-only visitors and devices are not counted on either path' do
    insert_ch_events([install(1, 3301, 1, device_id: 31)])
    stamp = at_noon(1)
    Clickhouse.with do |conn|
      conn.insert('purchase_events', [{
                    project_id: @project.id, event_type: 'buy', purchase_type: 'subscription', product_id: 'sku',
                    usd_price_cents: 999, currency: 'USD', quantity: 1, transaction_id: 'txn_mq', original_transaction_id: 'o',
                    store_source: 'apple', device_id: 32, visitor_id: 3302, link_id: 0, session_id: '', platform: 'ios',
                    purchase_date: stamp, recorded_at: stamp, created_at: stamp
                  }])
    end
    %w[unique_visitors unique_devices].each do |metric|
      rollup, raw = both_paths(metric: metric)
      assert_equal raw, rollup, metric
      assert_equal 1, rollup[:total], metric
    end
    events = Analytics::MetricQueryService.run(@project.id, query(metric: 'events', filters: RAW))
    assert_equal 2, events[:total][:value], 'the events metric still counts purchases'
  end

  test 'raw: a purchase filter keeps purchase rows in uniques' do
    insert_ch_events([install(1, 3401, 1, device_id: 41)])
    stamp = at_noon(1)
    Clickhouse.with do |conn|
      conn.insert('purchase_events', [{
                    project_id: @project.id, event_type: 'buy', purchase_type: 'subscription', product_id: 'sku_pro',
                    usd_price_cents: 999, currency: 'USD', quantity: 1, transaction_id: 'txn_pf', original_transaction_id: 'o',
                    store_source: 'apple', device_id: 42, visitor_id: 3402, link_id: 0, session_id: '', platform: 'ios',
                    purchase_date: stamp, recorded_at: stamp, created_at: stamp
                  }])
    end
    by_product = '[{"field":"purchase.product_id","operator":"is","value":"sku_pro"}]'
    by_type = '[{"field":"event_type","operator":"is","value":"purchase"}]'
    [by_product, by_type].each do |filters|
      %w[unique_visitors unique_devices].each do |metric|
        r = Analytics::MetricQueryService.run(@project.id, query(metric: metric, filters: filters))
        assert_equal 1, r[:total][:value], "#{metric} #{filters}"
      end
    end
  end

  test 'parity: a plan breakdown skips events without a plan on both paths' do
    insert_ch_events([
      install(1, 2901, 1, properties: { 'plan' => 'pro' }), install(2, 2902, 1, properties: { 'plan' => 'pro' }),
      install(3, 2903, 1, properties: { 'plan' => 'free' }), install(4, 2904, 1)
    ])
    %w[installs unique_visitors].each do |metric|
      rollup, raw = both_paths(metric: metric, group_by: 'properties.plan')
      assert_equal raw, rollup, metric
      assert_equal({ rows: { 'pro' => 2, 'free' => 1 }, total: 3 }, rollup, metric)
    end
  end

  test 'top-N ties break on the key so every branch picks the same keys' do
    keys = ('a'..'t').map { |c| "k#{c}" }
    insert_ch_events(keys.each_with_index.map { |k, i| install(i, 3000 + i, 1, city: k) })
    %w[installs unique_visitors].each do |metric|
      r = Analytics::MetricQueryService.run(@project.id, query(metric: metric, group_by: 'city', limit: '3', granularity: 'day'))
      assert_equal %w[ka kb kc], r[:rows].map { |x| x[:key] }, metric
      assert_equal [1, 1, 1], r[:rows].map { |x| x[:points].sum { |p| p[:value] } }, metric
      assert_equal 17, r[:other][:value], metric
      assert_equal 20, r[:total][:value], metric
    end
  end

  private

  def alias_visitor(from_id, to_id)
    Clickhouse.with do |conn|
      conn.insert('visitor_identity_map', [{ project_id: @project.id, from_visitor_id: from_id, to_visitor_id: to_id,
                                             updated_at: at_noon(0) }])
    end
  end

  # The os chip is a no-op filter that only switches the read to raw events.
  def both_paths(**params)
    rollup_q = query(params)
    raw_q = query(params.merge(filters: RAW))
    assert_not rollup_q.raw?
    assert raw_q.raw?
    [rollup_q, raw_q].map do |q|
      r = Analytics::MetricQueryService.run(@project.id, q)
      { rows: r[:rows].to_h { |x| [x[:key], x[:value]] }, total: r[:total][:value] }
    end
  end

  # Test env uses :null_store; a real store exercises Rails.cache.fetch memoization.
  def with_memory_cache
    previous_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    yield
  ensure
    Rails.cache = previous_cache
  end
end
