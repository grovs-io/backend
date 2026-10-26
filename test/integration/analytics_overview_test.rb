# frozen_string_literal: true

require 'test_helper'
require_relative 'auth_test_helper'
require_relative 'analytics_schema_helper'

class AnalyticsOverviewTest < ActionDispatch::IntegrationTest
  include AuthTestHelper
  include AnalyticsSchemaHelper

  fixtures :instances, :users, :instance_roles, :projects

  setup do
    @admin_user = users(:admin_user)
    @project = projects(:one)
    @headers = doorkeeper_headers_for(@admin_user)
  end

  # ── Auth & CH guard ──────────────────────────────────────────────────

  test 'returns 401 without auth token' do
    Clickhouse.stub(:read_enabled?, true) do
      get "#{API_PREFIX}/projects/#{@project.id}/analytics/overview/versions",
          headers: api_headers
    end
    assert_response :unauthorized
  end

  test 'returns 422 when start_date is after end_date' do
    Clickhouse.stub(:read_enabled?, true) do
      get "#{API_PREFIX}/projects/#{@project.id}/analytics/overview/versions",
          params: { start_date: '2026-05-01', end_date: '2026-04-01' },
          headers: @headers
    end
    assert_response :unprocessable_entity
  end

  test 'returns 503 with exact error body when CH disabled' do
    Clickhouse.stub(:read_enabled?, false) do
      get "#{API_PREFIX}/projects/#{@project.id}/analytics/overview/versions",
          headers: @headers
    end
    assert_response :service_unavailable
    assert_equal({ 'error' => 'Analytics temporarily unavailable' }, JSON.parse(response.body))
  end

  test 'overview: 503 error schema is strict' do
    Clickhouse.stub(:read_enabled?, false) do
      get "#{API_PREFIX}/projects/#{@project.id}/analytics/overview/versions",
          headers: @headers
    end
    assert_response :service_unavailable
    assert_analytics_schema(:error_response)
  end

  # ── GET /overview/key-metrics ────────────────────────────────────────

  test 'key_metrics: forwards dates and platform to service' do
    captured_args = nil
    fake = lambda { |*args, **kwargs|
      captured_args = [args, kwargs]
      { metrics: {} }
    }

    with_ch_stub(::Analytics::OverviewStatsService, :key_metrics, fake) do
      get "#{API_PREFIX}/projects/#{@project.id}/analytics/overview/key-metrics",
          params: { start_date: '2026-04-01', end_date: '2026-05-01', platform: 'ios' },
          headers: @headers
    end

    assert_response :ok
    assert_equal @project.id, captured_args[0][0]
    assert_equal Date.parse('2026-04-01'), captured_args[1][:start_date]
    assert_equal Date.parse('2026-05-01'), captured_args[1][:end_date]
    assert_equal 'ios', captured_args[1][:platform]
  end

  test 'key_metrics: response schema is strict' do
    result = { metrics: {
      views: 10, link_views: 8, opens: 3, installs: 2, link_driven_installs: 1,
      organic_installs: 1, reinstalls: 0, app_opens: 5, referred_users: 0,
      total_users: 4, new_users: 2, returning_users: 2, returning_rate: 0.5,
      revenue: 5000, units_sold: 4, cancellations: 1, first_time_purchases: 3,
      arpu: 1250.0, arppu: 2500.0
    }, unsupported_metrics: [] }

    with_ch_stub(::Analytics::OverviewStatsService, :key_metrics, result) do
      get "#{API_PREFIX}/projects/#{@project.id}/analytics/overview/key-metrics", headers: @headers
    end

    assert_response :ok
    assert_analytics_schema(:overview_key_metrics)
  end

  test 'key_metrics: forwards filters to service' do
    captured = nil
    fake = lambda { |*args, **kw| 
      captured = [args, kw]
      { metrics: {}, unsupported_metrics: [] }
    }
    filters = '[{"field":"country","operator":"is","value":"RO"}]'

    with_ch_stub(::Analytics::OverviewStatsService, :key_metrics, fake) do
      get "#{API_PREFIX}/projects/#{@project.id}/analytics/overview/key-metrics",
          params: { start_date: '2026-04-01', end_date: '2026-05-01', filters: filters }, headers: @headers
    end

    assert_response :ok
    assert_equal filters, captured[1][:filters]
  end

  test 'key_metrics: non-platform filters over 90 days return 422 query_too_heavy' do
    Clickhouse.stub(:read_enabled?, true) do
      get "#{API_PREFIX}/projects/#{@project.id}/analytics/overview/key-metrics",
          params: { start_date: (Date.current - 120).to_s, end_date: Date.current.to_s,
                    filters: '[{"field":"country","operator":"is","value":"RO"}]' },
          headers: @headers
    end
    assert_response :unprocessable_entity
    assert_equal 'query_too_heavy', JSON.parse(response.body)['error_code']
  end

  test 'key_metrics: unsupported chip returns 400 unsupported_filter' do
    Clickhouse.stub(:read_enabled?, true) do
      get "#{API_PREFIX}/projects/#{@project.id}/analytics/overview/key-metrics",
          params: { filters: '[{"field":"link_id","operator":"contains","value":"x"}]' },
          headers: @headers
    end
    assert_response :bad_request
    json = JSON.parse(response.body)
    assert_equal 'unsupported_filter', json['error_code']
    assert_equal 'Unsupported filter: link_id contains', json['error']
    assert_analytics_schema(:error_with_code, json)
  end

  test 'key_metrics: an integer chip without a value returns 400 unsupported_filter' do
    Clickhouse.stub(:read_enabled?, true) do
      get "#{API_PREFIX}/projects/#{@project.id}/analytics/overview/key-metrics",
          params: { filters: '[{"field":"link_id","operator":"is","value":null}]' },
          headers: @headers
    end
    assert_response :bad_request
    assert_equal 'unsupported_filter', JSON.parse(response.body)['error_code']
  end

  test 'key_metrics: platform-only chip over 90 days is still served' do
    fake = ->(*) { { metrics: {}, unsupported_metrics: [] } }
    with_ch_stub(::Analytics::OverviewStatsService, :key_metrics, fake) do
      get "#{API_PREFIX}/projects/#{@project.id}/analytics/overview/key-metrics",
          params: { start_date: (Date.current - 120).to_s, end_date: Date.current.to_s,
                    filters: '[{"field":"platform","operator":"is","value":"ios"}]' },
          headers: @headers
    end
    assert_response :ok
  end

  # ── GET /overview/key-metrics/series ─────────────────────────────────

  test 'key_metric_series: forwards metric, dates and platform to service' do
    captured_args = nil
    fake = lambda { |*args, **kwargs|
      captured_args = [args, kwargs]
      { metric: 'link_views', points: [] }
    }

    with_ch_stub(::Analytics::OverviewStatsService, :key_metric_series, fake) do
      get "#{API_PREFIX}/projects/#{@project.id}/analytics/overview/key-metrics/series",
          params: { metric: 'link_views', start_date: '2026-04-01', end_date: '2026-05-01', platform: 'ios' },
          headers: @headers
    end

    assert_response :ok
    assert_equal @project.id, captured_args[0][0]
    assert_equal 'link_views', captured_args[1][:metric]
    assert_equal Date.parse('2026-04-01'), captured_args[1][:start_date]
    assert_equal 'ios', captured_args[1][:platform]
  end

  test 'key_metric_series: accepts the revenue metric' do
    captured = nil
    fake = lambda { |*_args, **kwargs|
      captured = kwargs[:metric]
      { metric: 'revenue', points: [{ date: '2026-04-01', value: 1200 }] }
    }

    with_ch_stub(::Analytics::OverviewStatsService, :key_metric_series, fake) do
      get "#{API_PREFIX}/projects/#{@project.id}/analytics/overview/key-metrics/series",
          params: { metric: 'revenue', start_date: '2026-04-01', end_date: '2026-04-01' }, headers: @headers
    end

    assert_response :ok
    assert_equal 'revenue', captured
    assert_equal 1200, JSON.parse(response.body)['points'][0]['value']
  end

  test 'key_metric_series: invalid metric returns 400' do
    Clickhouse.stub(:read_enabled?, true) do
      get "#{API_PREFIX}/projects/#{@project.id}/analytics/overview/key-metrics/series",
          params: { metric: 'password_hash' },
          headers: @headers
    end
    assert_response :bad_request
    assert JSON.parse(response.body)['error'].include?('metric')
  end

  test 'key_metric_series: missing metric returns 400' do
    Clickhouse.stub(:read_enabled?, true) do
      get "#{API_PREFIX}/projects/#{@project.id}/analytics/overview/key-metrics/series",
          headers: @headers
    end
    assert_response :bad_request
  end

  test 'key_metric_series: response schema is strict' do
    result = { metric: 'link_views', points: [{ date: '2026-05-01', value: 12 }] }

    with_ch_stub(::Analytics::OverviewStatsService, :key_metric_series, result) do
      get "#{API_PREFIX}/projects/#{@project.id}/analytics/overview/key-metrics/series",
          params: { metric: 'link_views' },
          headers: @headers
    end

    assert_response :ok
    json = assert_analytics_schema(:overview_key_metric_series)
    assert_each_analytics_item(:series_point, json['points'])
  end

  test 'key_metric_series: serializes the unsupported flag' do
    result = { metric: 'revenue', points: [], unsupported: true }

    with_ch_stub(::Analytics::OverviewStatsService, :key_metric_series, result) do
      get "#{API_PREFIX}/projects/#{@project.id}/analytics/overview/key-metrics/series",
          params: { metric: 'revenue' },
          headers: @headers
    end

    assert_response :ok
    assert_equal true, assert_analytics_schema(:overview_key_metric_series)['unsupported']
  end

  test 'key_metric_series: forwards filters and granularity to service' do
    captured = nil
    fake = lambda { |*args, **kw| 
      captured = [args, kw]
      { metric: 'installs', points: [] }
    }

    with_ch_stub(::Analytics::OverviewStatsService, :key_metric_series, fake) do
      get "#{API_PREFIX}/projects/#{@project.id}/analytics/overview/key-metrics/series",
          params: { metric: 'installs', granularity: 'week',
                    filters: '[{"field":"os","operator":"is","value":"iOS 18"}]' },
          headers: @headers
    end

    assert_response :ok
    assert_equal 'week', captured[1][:granularity]
    assert_equal '[{"field":"os","operator":"is","value":"iOS 18"}]', captured[1][:filters]
  end

  test 'key_metric_series: unsupported chip returns 400 unsupported_filter' do
    Clickhouse.stub(:read_enabled?, true) do
      get "#{API_PREFIX}/projects/#{@project.id}/analytics/overview/key-metrics/series",
          params: { metric: 'installs', filters: '[{"field":"link_id","operator":"contains","value":"x"}]' },
          headers: @headers
    end
    assert_response :bad_request
    json = JSON.parse(response.body)
    assert_equal 'unsupported_filter', json['error_code']
    assert_analytics_schema(:error_with_code, json)
  end

  test 'key_metric_series: invalid granularity returns 400' do
    Clickhouse.stub(:read_enabled?, true) do
      get "#{API_PREFIX}/projects/#{@project.id}/analytics/overview/key-metrics/series",
          params: { metric: 'installs', granularity: 'hour' }, headers: @headers
    end
    assert_response :bad_request
  end

  # ── GET /overview/versions ───────────────────────────────────────────

  test 'versions: forwards dates and platform to service' do
    captured_args = nil
    fake = lambda { |*args, **kwargs| 
      captured_args = [args, kwargs]
      { platforms: {} }
    }

    with_ch_stub(::Analytics::OverviewStatsService, :versions, fake) do
      get "#{API_PREFIX}/projects/#{@project.id}/analytics/overview/versions",
          params: { start_date: '2026-04-01', end_date: '2026-05-01' },
          headers: @headers
    end

    assert_response :ok
    assert_equal Date.parse('2026-04-01'), captured_args[1][:start_date]
    assert_equal Date.parse('2026-05-01'), captured_args[1][:end_date]
  end

  test 'versions: controller passes service result through unchanged' do
    canary = { 'platforms' => { 'ios' => [{ 'version' => '2.0.0', 'users' => 100 }] } }

    with_ch_stub(::Analytics::OverviewStatsService, :versions, canary) do
      get "#{API_PREFIX}/projects/#{@project.id}/analytics/overview/versions", headers: @headers
    end

    assert_response :ok
    json = JSON.parse(response.body)
    assert_equal canary, json, 'Controller should pass service result through without modification'
  end

  test 'versions: empty returns empty hash' do
    with_ch_stub(::Analytics::OverviewStatsService, :versions, { platforms: {} }) do
      get "#{API_PREFIX}/projects/#{@project.id}/analytics/overview/versions", headers: @headers
    end
    assert_equal({ 'platforms' => {} }, JSON.parse(response.body))
  end

  # ── GET /overview/trends/users ───────────────────────────────────────

  test 'user_trends: forwards dates and platform to service' do
    captured_args = nil
    fake = lambda { |*args, **kwargs| 
      captured_args = [args, kwargs]
      { points: [] }
    }

    with_ch_stub(::Analytics::OverviewStatsService, :user_trends, fake) do
      get "#{API_PREFIX}/projects/#{@project.id}/analytics/overview/trends/users",
          params: { start_date: '2026-04-01', end_date: '2026-05-01', platform: 'android' },
          headers: @headers
    end

    assert_response :ok
    assert_equal Date.parse('2026-04-01'), captured_args[1][:start_date]
    assert_equal 'android', captured_args[1][:platform]
    assert_equal Analytics::RetentionPolicy.cutoff_for(@project.id), captured_args[1][:cutoff],
                 'controller must pass the resolved retention cutoff into the service'
  end

  test 'user_trends: controller passes service result through unchanged' do
    canary = { 'points' => [{ 'date' => '2026-05-01', 'new_users' => 99, 'previous_new_users' => 80 }] }

    with_ch_stub(::Analytics::OverviewStatsService, :user_trends, canary) do
      get "#{API_PREFIX}/projects/#{@project.id}/analytics/overview/trends/users", headers: @headers
    end

    assert_response :ok
    json = JSON.parse(response.body)
    assert_equal canary, json, 'Controller should pass service result through without modification'
  end

  test 'user_trends: forwards filters and granularity to service' do
    captured = nil
    fake = lambda { |*args, **kw| 
      captured = [args, kw]
      { points: [] }
    }

    with_ch_stub(::Analytics::OverviewStatsService, :user_trends, fake) do
      get "#{API_PREFIX}/projects/#{@project.id}/analytics/overview/trends/users",
          params: { granularity: 'month', filters: '[{"field":"country","operator":"is","value":"RO"}]' },
          headers: @headers
    end

    assert_response :ok
    assert_equal 'month', captured[1][:granularity]
    assert_equal '[{"field":"country","operator":"is","value":"RO"}]', captured[1][:filters]
  end

  test 'user_trends: unsupported chip returns 400 unsupported_filter' do
    Clickhouse.stub(:read_enabled?, true) do
      get "#{API_PREFIX}/projects/#{@project.id}/analytics/overview/trends/users",
          params: { filters: '[{"field":"link_id","operator":"contains","value":"x"}]' },
          headers: @headers
    end
    assert_response :bad_request
    json = JSON.parse(response.body)
    assert_equal 'unsupported_filter', json['error_code']
    assert_analytics_schema(:error_with_code, json)
  end

  test 'user_trends: heavy filter whose previous period enters cold storage returns 422' do
    policy = Struct.new(:queryable_cutoff_date, :cold_cutoff_date, :queryable_days, :hot_days)
                   .new(Date.current - 400, Date.current - 100, 400, 100)
    # minitest-mock has no stub_any_instance; swap the method on the class and restore it after.
    Api::V1::Analytics::OverviewController.class_eval { alias_method :__orig_retention_policy, :retention_policy }
    Api::V1::Analytics::OverviewController.send(:define_method, :retention_policy) { policy }
    begin
      Clickhouse.stub(:read_enabled?, true) do
        get "#{API_PREFIX}/projects/#{@project.id}/analytics/overview/trends/users",
            params: { start_date: (Date.current - 60).to_s, end_date: Date.current.to_s,
                      filters: '[{"field":"country","operator":"is_not","value":"RO"}]' },
            headers: @headers
      end
      assert_response :unprocessable_entity
      assert_equal 'heavy_filter_in_cold', JSON.parse(response.body)['error_code']
      assert_includes JSON.parse(response.body)['error'], 'last 100 days'
    ensure
      Api::V1::Analytics::OverviewController.class_eval do
        remove_method :retention_policy
        alias_method :retention_policy, :__orig_retention_policy
        remove_method :__orig_retention_policy
      end
    end
  end

  # ── GET /overview/sources/breakdown ──────────────────────────────────

  test 'sources_breakdown: forwards dates and platform to service' do
    captured_args = nil
    fake = lambda { |*args, **kwargs| 
      captured_args = [args, kwargs]
      { sources: [], total: 0 }
    }

    with_ch_stub(::Analytics::OverviewStatsService, :sources_breakdown, fake) do
      get "#{API_PREFIX}/projects/#{@project.id}/analytics/overview/sources/breakdown",
          params: { start_date: '2026-04-01', end_date: '2026-05-01' },
          headers: @headers
    end

    assert_response :ok
    assert_equal Date.parse('2026-04-01'), captured_args[1][:start_date]
    assert_nil captured_args[1][:platform]
  end

  test 'sources_breakdown: controller passes service result through unchanged' do
    canary = { 'sources' => [{ 'name' => 'Organic', 'value' => 100 }], 'total' => 100 }

    with_ch_stub(::Analytics::OverviewStatsService, :sources_breakdown, canary) do
      get "#{API_PREFIX}/projects/#{@project.id}/analytics/overview/sources/breakdown",
          headers: @headers
    end

    assert_response :ok
    json = JSON.parse(response.body)
    assert_equal canary, json, 'Controller should pass service result through without modification'
  end

  # ── GET /overview/versions/distribution ──────────────────────────────

  test 'version_distribution: forwards dates, platform, limit to service' do
    captured_args = nil
    fake = lambda { |*args, **kwargs| 
      captured_args = [args, kwargs]
      { entries: [] }
    }

    with_ch_stub(::Analytics::OverviewStatsService, :version_distribution, fake) do
      get "#{API_PREFIX}/projects/#{@project.id}/analytics/overview/versions/distribution",
          params: { start_date: '2026-04-01', end_date: '2026-05-01',
                    platform: 'ios', limit: '20' },
          headers: @headers
    end

    assert_response :ok
    assert_equal Date.parse('2026-04-01'), captured_args[1][:start_date]
    assert_equal 'ios', captured_args[1][:platform]
    assert_equal 20, captured_args[1][:limit]
  end

  test 'version_distribution: uses default limit=10 when not provided' do
    captured_args = nil
    fake = lambda { |*args, **kwargs| 
      captured_args = [args, kwargs]
      { entries: [] }
    }

    with_ch_stub(::Analytics::OverviewStatsService, :version_distribution, fake) do
      get "#{API_PREFIX}/projects/#{@project.id}/analytics/overview/versions/distribution",
          headers: @headers
    end

    assert_response :ok
    assert_equal 10, captured_args[1][:limit]
    assert_nil captured_args[1][:platform]
  end

  test 'version_distribution: controller passes service result through unchanged' do
    canary = { 'entries' => [{ 'version' => '1.0', 'release_date' => '2026-01-01',
                               'platforms' => { 'ios' => 100 }, 'total' => 100 }] }

    with_ch_stub(::Analytics::OverviewStatsService, :version_distribution, canary) do
      get "#{API_PREFIX}/projects/#{@project.id}/analytics/overview/versions/distribution",
          headers: @headers
    end

    assert_response :ok
    json = JSON.parse(response.body)
    assert_equal canary, json, 'Controller should pass service result through without modification'
  end

  # ── Invalid input validation ───────────────────────────────────────

  test 'version_distribution: non-integer limit falls back to default' do
    captured_args = nil
    fake = lambda { |*args, **kwargs| 
      captured_args = [args, kwargs]
      { entries: [] }
    }

    with_ch_stub(::Analytics::OverviewStatsService, :version_distribution, fake) do
      get "#{API_PREFIX}/projects/#{@project.id}/analytics/overview/versions/distribution",
          params: { limit: 'not_a_number' },
          headers: @headers
    end

    assert_response :ok
    assert_equal 10, captured_args[1][:limit]
  end

  # End-to-end heavy-query mapping with NO service-method stub: a heavy CH
  # DatabaseError (Code: 159 / TIMEOUT_EXCEEDED) raised at the connection layer must
  # flow through the real with_guard mapping AND the real OverviewStatsService rescue
  # path (its `rescue StandardError; log_query_failure` re-raises QueryTooHeavy) all the
  # way to the BaseController, yielding a 422 query_too_heavy envelope.
  test 'heavy CH error propagates through the real overview service to a 422 envelope' do
    heavy = lambda { |*_args, &_blk|
      raise ClickHouse::Client::DatabaseError,
            'Code: 159. DB::Exception: Timeout exceeded: TIMEOUT_EXCEEDED'
    }
    Clickhouse.stub(:read_enabled?, true) do
      Clickhouse.stub(:with, heavy) do
        get "#{API_PREFIX}/projects/#{@project.id}/analytics/overview/versions",
            params: { start_date: '2026-04-01', end_date: '2026-05-01' },
            headers: @headers
      end
    end

    assert_response :unprocessable_entity
    body = JSON.parse(response.body)
    assert_equal 'query_too_heavy', body['error_code']
    assert body['error'].present?
  end

  private

  def with_ch_stub(service, method, result, &block)
    Clickhouse.stub(:read_enabled?, true) do
      service.stub(method, result, &block)
    end
  end
end
