# frozen_string_literal: true

require 'test_helper'

class Analytics::MetricQueryTest < ActiveSupport::TestCase
  # Ruby 3 keyword rules: split declared keywords out of **kwargs so build(metric: ...) works.
  def build(overrides = {}, **kwargs)
    start_date = kwargs.delete(:start_date) || Date.new(2026, 9, 1)
    end_date = kwargs.delete(:end_date) || Date.new(2026, 9, 30)
    platform = kwargs.delete(:platform)
    cutoff = kwargs.delete(:cutoff)
    params = ActionController::Parameters.new({ metric: 'installs' }.merge(overrides).merge(kwargs))
    Analytics::MetricQuery.build(params, start_date: start_date, end_date: end_date, platform: platform, cutoff: cutoff)
  end

  test 'defaults: no group_by, no granularity, limit 10, compare off, rollup mode' do
    q = build
    assert_nil q.group_by
    assert_nil q.granularity
    assert_equal 10, q.limit
    assert_equal false, q.compare
    assert_equal false, q.raw?
    assert_equal '2026-09-01', q.start_day
    assert_equal '2026-09-30', q.end_day
  end

  test 'previous period is the equal-length range ending the day before start' do
    q = build
    assert_equal '2026-08-02', q.prev_start_day
    assert_equal '2026-08-31', q.prev_end_day
  end

  test 'the previous period never starts before the retention cutoff' do
    q = build(cutoff: Date.new(2026, 8, 20))
    assert_equal '2026-08-20', q.prev_start_day
    assert_equal '2026-08-31', q.prev_end_day
    assert_not_equal build.cache_key, q.cache_key
  end

  test 'rejects unknown metric, dimension, granularity and out-of-range limit' do
    assert_raises(Analytics::MetricQuery::Invalid) { build(metric: 'revenue') }
    assert_raises(Analytics::MetricQuery::Invalid) { build(group_by: 'ip') }
    assert_raises(Analytics::MetricQuery::Invalid) { build(granularity: 'hour') }
    assert_raises(Analytics::MetricQuery::Invalid) { build(limit: '0') }
    assert_raises(Analytics::MetricQuery::Invalid) { build(limit: '51') }
    assert_raises(Analytics::MetricQuery::Invalid) { build(group_by: 'properties.bad`key') }
  end

  test 'accepts properties.<key> and user.<key> dimensions' do
    assert_equal 'properties.plan', build(group_by: 'properties.plan').group_by
    assert_equal 'user.tier', build(group_by: 'user.tier').group_by
  end

  test 'raw dimension SQL maps platform, source, ids and json keys' do
    assert_equal ClickhouseReadService::NORMALIZED_PLATFORM_SQL, build(group_by: 'platform').plan(1)[:dim]
    assert_equal Analytics::SourceTaxonomy.expr, build(group_by: 'source', filters: '[{"field":"country","operator":"is","value":"RO"}]').plan(1)[:dim]
    assert_equal 'toString(link_id)', build(group_by: 'link_id').plan(1)[:dim]
    prop_query = build(group_by: 'properties.plan', filters: '[{"field":"os","operator":"is","value":"iOS"}]')
    assert_equal 'CAST(properties.`plan` AS String)', prop_query.plan(1)[:dim]
    assert_equal 'CAST(sdk_attributes.`tier` AS String)', build(group_by: 'user.tier').plan(1)[:dim]
    assert_equal "''", build.plan(1)[:dim]
  end

  test 'raw aggregate SQL for counters and uniques' do
    raw = { filters: '[{"field":"country","operator":"is","value":"RO"}]' }
    assert_equal 'count()', build(raw).plan(1)[:agg]
    assert_includes build(raw).plan(1)[:where], "event_type = '#{Grovs::Events::INSTALL}'"
    assert_equal 'count()', build(raw.merge(metric: 'link_views')).plan(1)[:agg]
    assert_includes build(raw.merge(metric: 'link_views')).plan(1)[:where], "event_type = '#{Grovs::Events::VIEW}'"
    assert_includes build(raw.merge(metric: 'link_views')).plan(1)[:where], 'link_id > 0'
    eff = Analytics::OverviewRawEvents::EFFECTIVE_VISITOR_SQL
    assert_equal "uniqIf(#{eff}, #{eff} > 0)", build(raw.merge(metric: 'unique_visitors')).plan(1)[:agg]
    assert_includes build(raw.merge(metric: 'unique_visitors')).plan(1)[:from], 'visitor_identity_map'
    assert_includes build(raw.merge(metric: 'unique_devices')).plan(1)[:where], Grovs::Events::NOT_A_MESSAGE_SQL
    assert_equal 'uniqIf(device_id, device_id > 0)', build(raw.merge(metric: 'unique_devices')).plan(1)[:agg]
  end

  test 'counters push the event type into the raw WHERE and count() everything left' do
    q = build(group_by: 'city')
    plan = q.plan(1)
    assert q.raw?
    assert_includes plan[:where], "event_type = '#{Grovs::Events::INSTALL}'"
    assert_equal 'count()', plan[:agg]
  end

  test 'link-only counters also require link_id > 0 in the raw WHERE' do
    plan = build(metric: 'link_driven_installs', group_by: 'city').plan(1)
    assert_includes plan[:where], "event_type = '#{Grovs::Events::INSTALL}'"
    assert_includes plan[:where], 'link_id > 0'
  end

  test 'events metric counts every matching row, never uses a rollup' do
    q = build(metric: 'events')
    assert q.raw?
    assert q.counter?
    plan = q.plan(1)
    assert_equal 'count()', plan[:agg]
    assert_not_includes plan[:where], 'event_type ='
  end

  test 'uniques keep uniqIf on the raw path and rollups keep sumIf' do
    assert_equal 'uniqIf(device_id, device_id > 0)', build(metric: 'unique_devices', group_by: 'city').plan(1)[:agg]
    assert_equal "sumIf(cnt, event_type = '#{Grovs::Events::INSTALL}')", build(group_by: 'country').plan(1)[:agg]
    assert_not build(metric: 'unique_visitors').counter?
  end

  test 'rollup plan is used for unfiltered typed dimensions and platform chips' do
    p = build(group_by: 'country', platform: 'ios').plan(1)
    assert_equal 'project_country_daily', p[:from]
    assert_equal 'country', p[:dim]
    assert_equal "sumIf(cnt, event_type = 'install')", p[:agg]
    assert_equal 'event_date', p[:date_expr]
    assert_includes p[:where], "event_date >= '2026-09-01'"
    assert_includes p[:where], "= 'ios'"
  end

  test 'rollup plan uses project_daily for no group_by and platform' do
    assert_equal 'project_daily', build.plan(1)[:from]
    p = build(group_by: 'platform', metric: 'unique_devices').plan(1)
    assert_equal 'project_daily', p[:from]
    assert_equal 'uniqMerge(devices_state)', p[:agg]
    assert_equal ClickhouseReadService.normalized_platform_sql, p[:dim]
  end

  test 'untyped rollups (app_version, source) serve unique_visitors only' do
    assert_equal 'project_version_daily', build(group_by: 'app_version', metric: 'unique_visitors').plan(1)[:from]
    assert_equal 'uniqMerge(visitors_state)', build(group_by: 'source', metric: 'unique_visitors').plan(1)[:agg]
    assert build(group_by: 'app_version').raw?, 'counters by version need raw events'
    assert build(group_by: 'source').raw?
  end

  test 'curated property rollups' do
    p = build(group_by: 'properties.plan').plan(1)
    assert_equal 'project_property_daily', p[:from]
    assert_equal 'property_value', p[:dim]
    assert_includes p[:where], "property_key = 'plan'"
    assert build(group_by: 'properties.other').raw?
  end

  test 'link metrics, non-rollup dimensions and non-platform filters go raw' do
    assert build(metric: 'link_views').raw?
    assert build(group_by: 'city').raw?
    assert build(filters: '[{"field":"country","operator":"is","value":"RO"}]').raw?
    p = build(group_by: 'city').plan(1)
    assert_includes p[:from], 'FROM events'
    assert_equal 'toDate(created_at)', p[:date_expr]
  end

  test 'window index SQL per granularity' do
    assert_equal "dateDiff('day', toDate('2026-09-01'), event_date)", build(granularity: 'day').window_sql('event_date')
    assert_equal "intDiv(dateDiff('day', toDate('2026-09-01'), event_date), 7)", build(granularity: 'week').window_sql('event_date')
    m = build(granularity: 'month', start_date: Date.new(2026, 1, 15), end_date: Date.new(2026, 3, 31)).window_sql('d')
    assert_equal "multiIf(d <= toDate('2026-02-14'), 0, d <= toDate('2026-03-14'), 1, 2)", m
  end

  test 'month window index is a constant when the range fits one window' do
    assert_equal '0', build(granularity: 'month').window_sql('event_date')
  end

  test 'previous plan shifts the date range' do
    p = build.plan(1, previous: true)
    assert_includes p[:where], "event_date >= '2026-08-02'"
    assert_includes p[:where], "event_date <= '2026-08-31'"
  end

  test 'cache key changes with every parameter' do
    a = build.cache_key
    assert_not_equal a, build(group_by: 'country').cache_key
    assert_not_equal a, build(granularity: 'week').cache_key
    assert_not_equal a, build(limit: '5').cache_key
    assert_not_equal a, build(compare: 'true').cache_key
    assert_not_equal a, build(platform: 'ios').cache_key
    assert_equal a, build.cache_key
  end
end
