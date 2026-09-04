# frozen_string_literal: true

require 'test_helper'
require_relative 'auth_test_helper'
require_relative 'analytics_schema_helper'

class AnalyticsRetentionTest < ActionDispatch::IntegrationTest
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
      get "#{API_PREFIX}/projects/#{@project.id}/analytics/retention/summary",
          headers: api_headers
    end
    assert_response :unauthorized
  end

  test 'returns 503 with error schema when CH disabled' do
    Clickhouse.stub(:read_enabled?, false) do
      get "#{API_PREFIX}/projects/#{@project.id}/analytics/retention/summary",
          headers: @headers
    end
    assert_response :service_unavailable
    json = assert_analytics_schema(:error_response)
    assert_equal 'Analytics temporarily unavailable', json['error']
  end

  # ── GET /retention/summary ──────────────────────────────────────────

  test 'summary: forwards granularity, platform, dates, and filters to service' do
    captured = nil
    fake = ->(*args, **kw) { captured = [args, kw]; empty_summary }

    filters = [{ field: 'country', operator: 'is', value: 'US' }].to_json
    with_ch_stub(::Analytics::RetentionService, :summary, fake) do
      get "#{API_PREFIX}/projects/#{@project.id}/analytics/retention/summary",
          params: { granularity: 'monthly', platform: 'ios',
                    start_date: '2026-03-01', end_date: '2026-05-15',
                    filters: filters },
          headers: @headers
    end

    assert_response :ok
    assert_equal @project.id, captured[0][0]
    assert_equal 'monthly', captured[1][:granularity]
    assert_equal 'ios', captured[1][:platform]
    assert_equal Date.parse('2026-03-01'), captured[1][:start_date]
    assert_equal Date.parse('2026-05-15'), captured[1][:end_date]
    assert_equal filters, captured[1][:filters]
  end

  test 'summary: uses defaults when no params provided' do
    captured = nil
    fake = ->(*args, **kw) { captured = [args, kw]; empty_summary }

    with_ch_stub(::Analytics::RetentionService, :summary, fake) do
      get "#{API_PREFIX}/projects/#{@project.id}/analytics/retention/summary",
          headers: @headers
    end

    assert_response :ok
    assert_equal 'weekly', captured[1][:granularity]
    assert_nil captured[1][:platform]
    assert_equal 30.days.ago.to_date, captured[1][:start_date]
    assert_equal Date.current, captured[1][:end_date]
    assert_equal [], captured[1][:filters]
  end

  test 'summary: controller passes service result through unchanged' do
    canary = {
      'day_1' => 65.2, 'day_7' => 40.1, 'day_30' => 18.5,
      'sparkline' => [{ 'canary_date' => '2026-04-01' }],
      'median_churn_day' => 7, 'extra_field' => 'present'
    }

    with_ch_stub(::Analytics::RetentionService, :summary, canary) do
      get "#{API_PREFIX}/projects/#{@project.id}/analytics/retention/summary", headers: @headers
    end

    assert_response :ok
    json = JSON.parse(response.body)
    assert_equal canary, json, 'Controller should pass service result through without modification'
  end

  test 'summary: nil values when no data passes through unchanged' do
    with_ch_stub(::Analytics::RetentionService, :summary, empty_summary) do
      get "#{API_PREFIX}/projects/#{@project.id}/analytics/retention/summary", headers: @headers
    end

    json = JSON.parse(response.body)
    assert_nil json['day_1']
    assert_nil json['day_7']
    assert_nil json['day_30']
    assert_nil json['median_churn_day']
    assert_equal [], json['sparkline']
  end

  # ── Invalid input validation ───────────────────────────────────────

  test 'summary: invalid granularity returns 400' do
    Clickhouse.stub(:read_enabled?, true) do
      get "#{API_PREFIX}/projects/#{@project.id}/analytics/retention/summary",
          params: { granularity: 'daily' },
          headers: @headers
    end
    assert_response :bad_request
    json = JSON.parse(response.body)
    assert json['error'].include?('granularity')
  end

  private

  def with_ch_stub(service, method, result, &block)
    Clickhouse.stub(:read_enabled?, true) do
      service.stub(method, result, &block)
    end
  end

  def empty_summary
    { day_1: nil, day_7: nil, day_30: nil, sparkline: [], median_churn_day: nil }
  end
end
