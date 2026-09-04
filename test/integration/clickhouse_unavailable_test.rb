# frozen_string_literal: true

require 'test_helper'
require_relative 'auth_test_helper'
require_relative 'analytics_schema_helper'

class ClickhouseUnavailableTest < ActionDispatch::IntegrationTest
  include AuthTestHelper
  include AnalyticsSchemaHelper

  fixtures :instances, :users, :instance_roles, :projects

  setup do
    @project = projects(:one)
    @headers = doorkeeper_headers_for(users(:admin_user))
    @down = ->(*) { raise ClickHouse::Client::DatabaseError, 'Code: 210. DB::NetException: Connection refused. (NETWORK_ERROR)' }
    Rails.application.config.clickhouse_read_enabled = true
  end

  test 'a ClickHouse outage under primary renders the coded 503 envelope' do
    Rails.application.config.clickhouse_primary = true

    Clickhouse.stub(:with, @down) do
      get "#{API_PREFIX}/projects/#{@project.id}/analytics/overview/versions", headers: @headers
    end

    assert_response :service_unavailable
    body = assert_analytics_schema(:error_with_code)
    assert_equal 'clickhouse_unavailable', body['error_code']
  end

  test 'the same outage without primary does not 503' do
    Clickhouse.stub(:with, @down) do
      get "#{API_PREFIX}/projects/#{@project.id}/analytics/overview/versions", headers: @headers
    end

    assert_response :success
  end

  test 'a dead rollup rebuild under primary renders its own coded 503, not zeros' do
    Rails.application.config.clickhouse_primary = true
    Rails.application.config.clickhouse_analytics_rollups_read_enabled = true

    # Stubbed, not cleared: the stamp is shared Redis state, so clearing it races.
    ClickhouseRollupLiveness.stub(:fresh?, false) do
      get "#{API_PREFIX}/projects/#{@project.id}/analytics/overview/versions", headers: @headers
    end

    assert_response :service_unavailable
    body = assert_analytics_schema(:error_with_code)
    assert_equal 'clickhouse_stale', body['error_code']
  end

  test 'a ledger failure under primary renders its own coded 503, shadow writes or not' do
    Rails.application.config.clickhouse_primary = true
    down = ->(*, **) { raise ActiveRecord::StatementInvalid, 'ledger down' }

    assert Grovs.pg_shadow_writes?, 'the soak runs with the stat tables still warm'
    RevenueLedgerQuery.stub(:base, down) do
      post "#{API_PREFIX}/projects/#{@project.id}/dashboard/metrics_overview",
           params: { start_date: '2026-06-01', end_date: '2026-06-30' }, headers: @headers
    end

    assert_response :service_unavailable
    assert_equal 'revenue_unavailable', JSON.parse(response.body)['error_code']
  end

  test 'a ledger failure without primary still degrades to the warm stat tables' do
    Rails.application.config.revenue_reads_from_ledger = true
    down = ->(*, **) { raise ActiveRecord::StatementInvalid, 'ledger down' }

    RevenueLedgerQuery.stub(:base, down) do
      post "#{API_PREFIX}/projects/#{@project.id}/dashboard/metrics_overview",
           params: { start_date: '2026-06-01', end_date: '2026-06-30' }, headers: @headers
    end

    assert_response :success
  end

  test 'the deprecated links_views series is gone rather than serving its frozen table' do
    ENV['PG_SHADOW_WRITES'] = 'false'
    begin
      post "#{API_PREFIX}/projects/#{@project.id}/dashboard/links_views",
           params: { start_date: '2026-06-01', end_date: '2026-06-30' }, headers: @headers
    ensure
      ENV.delete('PG_SHADOW_WRITES')
    end

    assert_response :gone
    assert_equal 'endpoint_retired', JSON.parse(response.body)['error_code']
  end

  test 'analytics switched off is a different 503 carrying no error_code' do
    Rails.application.config.clickhouse_read_enabled = false

    get "#{API_PREFIX}/projects/#{@project.id}/analytics/overview/versions", headers: @headers

    assert_response :service_unavailable
    assert_nil JSON.parse(response.body)['error_code']
  end
end
