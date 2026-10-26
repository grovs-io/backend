# frozen_string_literal: true

require 'test_helper'
require_relative 'auth_test_helper'
require_relative 'analytics_schema_helper'

class AnalyticsQueryTest < ActionDispatch::IntegrationTest
  include AuthTestHelper
  include AnalyticsSchemaHelper

  fixtures :instances, :users, :instance_roles, :projects

  setup do
    @admin_user = users(:admin_user)
    @project = projects(:one)
    @headers = doorkeeper_headers_for(@admin_user)
    @url = "#{API_PREFIX}/projects/#{@project.id}/analytics/query"
  end

  STUB = { metric: 'installs', group_by: 'country',
           rows: [{ key: 'RO', label: 'RO', value: 3, previous: nil, points: nil }],
           other: nil, total: { value: 3, previous: nil } }.freeze

  test 'returns 401 without auth token' do
    Clickhouse.stub(:read_enabled?, true) { get @url, params: { metric: 'installs' }, headers: api_headers }
    assert_response :unauthorized
  end

  test 'forwards a validated MetricQuery to the service' do
    captured = nil
    fake = lambda { |pid, q|
      captured = [pid, q]
      STUB
    }
    with_ch_stub(::Analytics::MetricQueryService, :run, fake) do
      get @url, params: { metric: 'installs', group_by: 'country', granularity: 'week', limit: '5', compare: 'true',
                          start_date: '2026-09-01', end_date: '2026-09-30', platform: 'ios' }, headers: @headers
    end
    assert_response :ok
    assert_equal @project.id, captured[0]
    q = captured[1]
    assert_equal 'installs', q.metric
    assert_equal 'country', q.group_by
    assert_equal 'week', q.granularity
    assert_equal 5, q.limit
    assert_equal true, q.compare
    assert_equal 'ios', q.resolved.platform
    assert_analytics_schema(:metric_query)
  end

  test 'compare reads no earlier than the plan retention cutoff' do
    captured = nil
    fake = lambda { |_pid, q|
      captured = q
      STUB
    }
    cutoff = ::Analytics::RetentionPolicy.for(@project.instance).queryable_cutoff_date
    with_ch_stub(::Analytics::MetricQueryService, :run, fake) do
      get @url, params: { metric: 'installs', compare: 'true', start_date: (cutoff + 2).to_s, end_date: (cutoff + 11).to_s }, headers: @headers
    end
    assert_response :ok
    assert_equal cutoff.strftime('%Y-%m-%d'), captured.prev_start_day
  end

  test 'invalid metric, group_by, granularity or limit return 400' do
    Clickhouse.stub(:read_enabled?, true) do
      get @url, params: { metric: 'nope' }, headers: @headers
      assert_response :bad_request
      get @url, params: { metric: 'installs', group_by: 'ip' }, headers: @headers
      assert_response :bad_request
      get @url, params: { metric: 'installs', granularity: 'hour' }, headers: @headers
      assert_response :bad_request
      get @url, params: { metric: 'installs', limit: '500' }, headers: @headers
      assert_response :bad_request
    end
  end

  test 'raw path over 90 days returns 422 query_too_heavy; rollup path is served' do
    Clickhouse.stub(:read_enabled?, true) do
      get @url, params: { metric: 'unique_visitors', group_by: 'city', start_date: (Date.current - 120).to_s, end_date: Date.current.to_s }, headers: @headers
      assert_response :unprocessable_entity
      assert_equal 'query_too_heavy', JSON.parse(response.body)['error_code']
    end
    with_ch_stub(::Analytics::MetricQueryService, :run, ->(*) { STUB }) do
      get @url, params: { metric: 'installs', group_by: 'country', start_date: (Date.current - 120).to_s, end_date: Date.current.to_s }, headers: @headers
    end
    assert_response :ok
  end

  test 'raw counters are capped at RAW_COUNTER_MAX_RANGE_DAYS, uniques and heavy chips at RAW_MAX_RANGE_DAYS' do
    long = { start_date: (Date.current - 200).to_s, end_date: Date.current.to_s }
    too_long = { start_date: (Date.current - 400).to_s, end_date: Date.current.to_s }
    heavy = JSON.generate([{ field: 'event_name', operator: 'is_not', value: 'buy' }])
    # Retention window stubbed wide open: isolates the raw-cap assertions from the plan fixture.
    policy = Struct.new(:queryable_cutoff_date, :cold_cutoff_date, :queryable_days).new(Date.current - 1000, Date.current - 1000, 1000)
    Api::V1::Analytics::QueryController.class_eval do
      alias_method :__orig_retention_policy, :retention_policy
      define_method(:retention_policy) { policy }
    end
    Clickhouse.stub(:read_enabled?, true) do
      Analytics::MetricQueryService.stub(:run, STUB) do
        get @url, params: long.merge(metric: 'installs', group_by: 'city'), headers: @headers
        assert_response :ok
        get @url, params: long.merge(metric: 'events', group_by: 'city'), headers: @headers
        assert_response :ok
        get @url, params: long.merge(metric: 'unique_visitors', group_by: 'city'), headers: @headers
        assert_response :unprocessable_entity
        assert_equal 'query_too_heavy', JSON.parse(response.body)['error_code']
        get @url, params: long.merge(metric: 'installs', group_by: 'city', filters: heavy), headers: @headers
        assert_response :unprocessable_entity
        get @url, params: too_long.merge(metric: 'installs', group_by: 'city'), headers: @headers
        assert_response :unprocessable_entity
        assert_match(/366 days/, JSON.parse(response.body)['error'])
      end
    end
  ensure
    Api::V1::Analytics::QueryController.class_eval do
      alias_method :retention_policy, :__orig_retention_policy
      remove_method :__orig_retention_policy
    end
  end

  test 'rollup path is capped at the plan queryable window' do
    ran = false
    with_ch_stub(::Analytics::MetricQueryService, :run, lambda { |*|
      ran = true
      STUB
    }) do
      get @url, params: { metric: 'installs', granularity: 'day', start_date: Date.current.to_s, end_date: '9999-12-31' },
                headers: @headers
    end
    assert_response :unprocessable_entity
    assert_equal 'query_too_heavy', JSON.parse(response.body)['error_code']
    assert_not ran
  end

  test 'compare judges the cold guard on the previous period start' do
    policy = Struct.new(:queryable_cutoff_date, :cold_cutoff_date, :queryable_days, :hot_days)
                   .new(Date.current - 400, Date.current - 100, 400, 100)
    Api::V1::Analytics::QueryController.class_eval do
      alias_method :__orig_retention_policy, :retention_policy
      define_method(:retention_policy) { policy }
    end
    Clickhouse.stub(:read_enabled?, true) do
      get @url, params: { metric: 'installs', group_by: 'city', compare: 'true',
                          start_date: (Date.current - 60).to_s, end_date: Date.current.to_s,
                          filters: '[{"field":"country","operator":"is_not","value":"RO"}]' }, headers: @headers
    end
    assert_response :unprocessable_entity
    assert_equal 'heavy_filter_in_cold', JSON.parse(response.body)['error_code']
  ensure
    Api::V1::Analytics::QueryController.class_eval do
      remove_method :retention_policy
      alias_method :retention_policy, :__orig_retention_policy
      remove_method :__orig_retention_policy
    end
  end

  test 'unsupported chips return 400 unsupported_filter' do
    chips = JSON.generate([{ field: 'link_id', operator: 'contains', value: 'x' }])
    Clickhouse.stub(:read_enabled?, true) do
      get @url, params: { metric: 'installs', filters: chips }, headers: @headers
    end
    assert_response :bad_request
    body = JSON.parse(response.body)
    assert_equal 'unsupported_filter', body['error_code']
    assert_equal 'Unsupported filter: link_id contains', body['error']
    assert_analytics_schema(:error_with_code, body)
  end

  test 'integer chips with a missing or non-numeric value return 400 unsupported_filter' do
    [nil, '', 'abc', [], [nil]].each do |value|
      chips = JSON.generate([{ field: 'visitor_id', operator: 'is', value: value }])
      Clickhouse.stub(:read_enabled?, true) do
        get @url, params: { metric: 'installs', filters: chips }, headers: @headers
      end
      assert_response :bad_request, "value #{value.inspect}"
      assert_equal 'unsupported_filter', JSON.parse(response.body)['error_code']
    end
  end

  test 'segment_id and search return 400 instead of being ignored' do
    [{ segment_id: '1' }, { search: 'x' }].each do |extra|
      Clickhouse.stub(:read_enabled?, true) do
        get @url, params: { metric: 'installs' }.merge(extra), headers: @headers
      end
      assert_response :bad_request, extra.inspect
      assert_analytics_schema(:error_with_code, JSON.parse(response.body))
    end
  end

  test 'response schema is strict' do
    with_ch_stub(::Analytics::MetricQueryService, :run, ->(*) { STUB }) do
      get @url, params: { metric: 'installs', group_by: 'country' }, headers: @headers
    end
    assert_response :ok
    assert_analytics_schema(:metric_query)
    assert_each_analytics_item(:metric_query_row, JSON.parse(response.body)['rows'])
  end

  private

  def with_ch_stub(service, method, result, &block)
    Clickhouse.stub(:read_enabled?, true) do
      service.stub(method, result, &block)
    end
  end
end
