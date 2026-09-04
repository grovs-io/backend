# frozen_string_literal: true

# End-to-end integration tests that exercise the full controller → service → ClickHouse path.
# These are CH-gated: skipped when ClickHouse is not available.
# Complements the stub-based integration tests that verify auth/routing/response shape.

require 'test_helper'
require_relative 'auth_test_helper'
require_relative 'analytics_schema_helper'

class AnalyticsEndToEndTest < ActionDispatch::IntegrationTest
  include AuthTestHelper
  include ClickhouseTestHelper
  include AnalyticsSchemaHelper

  fixtures :instances, :users, :instance_roles, :projects

  setup do
    skip_unless_clickhouse!
    @admin_user = users(:admin_user)
    @project = projects(:one)
    @headers = doorkeeper_headers_for(@admin_user)
    @now = Time.current
  end

  # --- Events Explorer ---

  test 'events index returns real CH data end-to-end' do
    insert_test_events
    Clickhouse.stub(:read_enabled?, true) do
      get "#{API_PREFIX}/projects/#{@project.id}/analytics/events",
          params: { start_date: 7.days.ago.to_date.to_s, end_date: Date.current.to_s },
          headers: @headers
    end
    assert_response :ok
    json = JSON.parse(response.body)
    assert json['data'].is_a?(Array)
    assert json['data'].size > 0
    assert_nil json['total_count'] # not requested

    # Schema validation
    assert_analytics_schema(:events_index, json)
    assert_each_analytics_item(:event_item, json['data']) if json['data'].any?
  end

  test 'events index with include_count returns total' do
    insert_test_events
    Clickhouse.stub(:read_enabled?, true) do
      get "#{API_PREFIX}/projects/#{@project.id}/analytics/events",
          params: { start_date: 7.days.ago.to_date.to_s, end_date: Date.current.to_s, include_count: 'true' },
          headers: @headers
    end
    assert_response :ok
    json = JSON.parse(response.body)
    assert json['total_count'] > 0

    # Schema validation
    assert_analytics_schema(:events_index, json)
    assert_each_analytics_item(:event_item, json['data']) if json['data'].any?
  end

  test 'events volume returns real histogram' do
    insert_test_events
    Clickhouse.stub(:read_enabled?, true) do
      get "#{API_PREFIX}/projects/#{@project.id}/analytics/events/volume",
          params: { start_date: 7.days.ago.to_date.to_s, end_date: Date.current.to_s },
          headers: @headers
    end
    assert_response :ok
    json = JSON.parse(response.body)
    assert json['buckets'].is_a?(Array)

    # Schema validation
    assert_analytics_schema(:events_volume, json)
    assert_each_analytics_item(:volume_bucket, json['buckets']) if json['buckets'].any?
  end

  # --- Overview ---

  test 'overview user_trends returns real data' do
    insert_test_events
    Clickhouse.stub(:read_enabled?, true) do
      get "#{API_PREFIX}/projects/#{@project.id}/analytics/overview/trends/users",
          params: { start_date: 7.days.ago.to_date.to_s, end_date: Date.current.to_s },
          headers: @headers
    end
    assert_response :ok
    json = JSON.parse(response.body)
    assert json['points'].is_a?(Array)

    # Schema validation
    assert_analytics_schema(:user_trends, json)
    assert_each_analytics_item(:trend_point, json['points']) if json['points'].any?
  end

  # --- Sessions ---

  test 'sessions index returns real session data end-to-end' do
    insert_test_session_data
    Clickhouse.stub(:read_enabled?, true) do
      get "#{API_PREFIX}/projects/#{@project.id}/analytics/sessions",
          params: { start_date: 7.days.ago.to_date.to_s, end_date: Date.current.to_s },
          headers: @headers
    end
    assert_response :ok
    json = JSON.parse(response.body)
    assert json['data'].is_a?(Array)
    assert json['data'].size > 0

    # Schema validation
    assert_analytics_schema(:sessions_index, json)
    assert_each_analytics_item(:session_summary_item, json['data']) if json['data'].any?
  end

  test 'sessions detail returns the session + its events end-to-end via the opaque key' do
    ts = @now.utc
    insert_ch_session_summaries({
      project_id: @project.id, session_id: 'e2e_detail', visitor_id: 5150,
      event_date: ts.to_date.to_s, platform: 'ios', app_version: '1.0.0',
      event_count: 2, duration_ms: 60_000, has_conversion: 0,
      started_at: ts.strftime('%Y-%m-%d %H:%M:%S.%3N'),
      ended_at: (ts + 60.seconds).strftime('%Y-%m-%d %H:%M:%S.%3N')
    })
    insert_ch_session_events([
      { project_id: @project.id, session_id: 'e2e_detail', visitor_id: 5150, event_type: 'OPEN',
        created_at: ts.strftime('%Y-%m-%d %H:%M:%S.%3N') },
      { project_id: @project.id, session_id: 'e2e_detail', visitor_id: 5150, event_type: 'VIEW',
        screen_name: 'HomeScreen', created_at: (ts + 30.seconds).strftime('%Y-%m-%d %H:%M:%S.%3N') }
    ])

    # 1) list → grab the opaque id for our session
    key = nil
    Clickhouse.stub(:read_enabled?, true) do
      get "#{API_PREFIX}/projects/#{@project.id}/analytics/sessions",
          params: { start_date: 7.days.ago.to_date.to_s, end_date: Date.current.to_s },
          headers: @headers
      row = JSON.parse(response.body)['data'].find { |r| r['session_id'] == 'e2e_detail' }
      key = row['id']
    end
    assert key.present?, 'list row exposes an opaque detail id'

    # 2) detail → resolve that id against real CH
    Clickhouse.stub(:read_enabled?, true) do
      get "#{API_PREFIX}/projects/#{@project.id}/analytics/sessions/#{key}", headers: @headers
    end
    assert_response :ok
    json = JSON.parse(response.body)
    assert_analytics_schema(:sessions_show, json)
    assert_equal 'e2e_detail', json['session']['session_id']
    assert_equal %w[OPEN VIEW], json['events'].map { |e| e['event_type'] }
    assert_each_analytics_item(:session_event_item, json['events'])
  end

  # --- Retention ---

  test 'retention summary returns real rates end-to-end' do
    insert_retention_data
    Clickhouse.stub(:read_enabled?, true) do
      get "#{API_PREFIX}/projects/#{@project.id}/analytics/retention/summary",
          headers: @headers
    end
    assert_response :ok
    json = JSON.parse(response.body)
    assert json.key?('day_1')
    assert json.key?('day_7')
    assert json.key?('day_30')
    assert json['sparkline'].is_a?(Array)

    # Schema validation
    assert_analytics_schema(:retention_summary, json)
    assert_each_analytics_item(:sparkline_point, json['sparkline']) if json['sparkline'].any?
  end

  # --- Param parsing edge cases ---

  test 'events index with filters param parses correctly end-to-end' do
    insert_test_events
    Clickhouse.stub(:read_enabled?, true) do
      get "#{API_PREFIX}/projects/#{@project.id}/analytics/events",
          params: {
            start_date: 7.days.ago.to_date.to_s,
            end_date: Date.current.to_s,
            filters: [{ field: 'event_type', operator: 'is', value: 'VIEW' }]
          },
          headers: @headers
    end
    assert_response :ok
    json = JSON.parse(response.body)
    assert json['data'].is_a?(Array)
    json['data'].each do |event|
      assert_equal 'VIEW', event['event_type']
    end

    # Schema validation
    assert_analytics_schema(:events_index, json)
    assert_each_analytics_item(:event_item, json['data']) if json['data'].any?
  end

  private

  def insert_test_events
    rows = 5.times.map do |i|
      {
        project_id: @project.id,
        event_type: i.even? ? 'VIEW' : 'OPEN',
        event_name: "test_event_#{i}",
        visitor_id: 1000 + i,
        platform: 'ios',
        created_at: (@now - i.hours).utc.strftime('%Y-%m-%d %H:%M:%S.%3N')
      }
    end
    insert_ch_events(rows)
  end

  def insert_test_session_data
    rows = 3.times.map do |i|
      {
        project_id: @project.id,
        session_id: "e2e_session_#{i}",
        visitor_id: 2000 + i,
        event_date: Date.current.to_s,
        platform: 'ios',
        app_version: '1.0.0',
        screen_count: 3,
        event_count: 5,
        duration_ms: 30_000,
        first_screen: 'HomeScreen',
        last_screen: 'SettingsScreen',
        has_conversion: 0,
        tracking_source: i.zero? ? '' : 'campaign_1',
        started_at: (@now - i.hours).utc.strftime('%Y-%m-%d %H:%M:%S.%3N'),
        ended_at: (@now - i.hours + 30.seconds).utc.strftime('%Y-%m-%d %H:%M:%S.%3N')
      }
    end
    insert_ch_session_summaries(rows)
  end

  def insert_retention_data
    profiles = []
    visitor_rows = []

    5.times do |i|
      visitor_id = 5000 + i
      first_seen = (@now - 14.days).utc.strftime('%Y-%m-%d %H:%M:%S.%3N')

      profiles << {
        project_id: @project.id,
        visitor_id: visitor_id,
        first_seen: first_seen,
        last_seen: @now.utc.strftime('%Y-%m-%d %H:%M:%S.%3N'),
        platform: 'ios'
      }

      next unless i < 3

      visitor_rows << {
        project_id: @project.id,
        visitor_id: visitor_id,
        event_date: (@now - 13.days).to_date.to_s,
        event_type: 'OPEN',
        platform: 'ios',
        cnt: 1,
        total_engagement_time: 1000,
        inviter_id_state: 0
      }
    end

    insert_ch_user_profiles(profiles)
    insert_ch_visitor_daily(visitor_rows)
  end
end
