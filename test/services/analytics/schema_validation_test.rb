# frozen_string_literal: true

require 'test_helper'
require_relative '../../integration/analytics_schema_helper'

# Validates real ClickHouse service output against OUTPUT_SCHEMAS.
# Unlike the integration tests (which stub services), these tests call the
# actual service methods against a live ClickHouse and validate that the
# returned data structures match the documented API contract.
class Analytics::SchemaValidationTest < ActiveSupport::TestCase
  include ClickhouseTestHelper
  include AnalyticsSchemaHelper

  fixtures :projects, :instances

  setup do
    skip_unless_clickhouse!
    @project = projects(:one)
    @now = Time.current
    seed_all_test_data
  end

  # =========================================================================
  # EventsQueryService
  # =========================================================================

  test 'EventsQueryService.list output matches events_index schema' do
    result = Analytics::EventsQueryService.list(
      @project.id,
      start_date: 30.days.ago.to_date,
      end_date: Date.current,
      include_count: true
    )
    json = deep_stringify(result)
    assert_analytics_schema(:events_index, json)
    assert json['data'].size > 0, 'Expected non-empty event data'
    assert_each_analytics_item(:event_item, json['data'])
  end

  test 'EventsQueryService.find output matches event_item schema' do
    events = ch_select_events(@project.id)
    event_id = events.first['event_id']

    found = Analytics::EventsQueryService.find(@project.id, event_id: event_id)
    assert_not_nil found, 'Expected to find event by event_id'
    json = deep_stringify({ 'data' => found })
    assert_analytics_schema(:event_show, json)
    # Validate the inner event item
    validate_analytics_object(
      deep_stringify(found), OUTPUT_SCHEMAS[:event_item],
      path: 'event_item', strict: false
    )
  end

  test 'EventsQueryService.volume output matches events_volume schema' do
    result = Analytics::EventsQueryService.volume(
      @project.id,
      start_date: 30.days.ago.to_date,
      end_date: Date.current
    )
    json = deep_stringify(result)
    assert_analytics_schema(:events_volume, json)
    assert json['buckets'].size > 0, 'Expected non-empty buckets'
    assert_each_analytics_item(:volume_bucket, json['buckets'])
  end

  test 'EventsQueryService.field_values output matches events_field_values schema' do
    result = Analytics::EventsQueryService.field_values(
      @project.id,
      field: 'platform'
    )
    json = deep_stringify(result)
    assert_analytics_schema(:events_field_values, json)
    assert json['values'].size > 0, 'Expected non-empty field values'
  end

  test 'EventsQueryService.fields output matches events_fields schema' do
    result = Analytics::EventsQueryService.fields(@project.id)
    json = deep_stringify(result)
    assert_analytics_schema(:events_fields, json)
    assert json['fields'].size > 0, 'Expected non-empty fields'
    assert_each_analytics_item(:field_item, json['fields'])
  end

  # =========================================================================
  # OverviewStatsService
  # =========================================================================

  test 'OverviewStatsService.versions output matches overview_versions schema' do
    result = Analytics::OverviewStatsService.versions(
      @project.id,
      start_date: 30.days.ago.to_date,
      end_date: Date.current
    )
    json = deep_stringify(result)
    assert_analytics_schema(:overview_versions, json)
    assert json['platforms'].is_a?(Hash), 'Expected platforms to be a Hash'
    assert json['platforms'].size > 0, 'Expected non-empty platforms'
    json['platforms'].each_value do |items|
      assert_each_analytics_item(:version_users_item, items)
    end
  end

  test 'OverviewStatsService.version_distribution output matches version_distribution schema' do
    result = Analytics::OverviewStatsService.version_distribution(
      @project.id,
      start_date: 30.days.ago.to_date,
      end_date: Date.current
    )
    json = deep_stringify(result)
    assert_analytics_schema(:version_distribution, json)
    assert json['entries'].size > 0, 'Expected non-empty distribution'
    assert_each_analytics_item(:distribution_item, json['entries'])
  end

  test 'OverviewStatsService.user_trends output matches user_trends schema' do
    result = Analytics::OverviewStatsService.user_trends(
      @project.id,
      start_date: 30.days.ago.to_date,
      end_date: Date.current
    )
    json = deep_stringify(result)
    assert_analytics_schema(:user_trends, json)
    # user_trends queries project_daily MV which only populates via inserts
    # through the MV pipeline. If empty, schema still validates.
    json['points'].each do |point|
      validate_analytics_object(
        deep_stringify(point), OUTPUT_SCHEMAS[:trend_point],
        path: 'trend_point', strict: true
      )
    end
  end

  test 'OverviewStatsService.sources_breakdown output matches sources_breakdown schema' do
    result = Analytics::OverviewStatsService.sources_breakdown(
      @project.id,
      start_date: 30.days.ago.to_date,
      end_date: Date.current
    )
    json = deep_stringify(result)
    assert_analytics_schema(:sources_breakdown, json)
    assert json['sources'].size > 0, 'Expected non-empty sources'
    assert_each_analytics_item(:source_item, json['sources'])
  end

  # =========================================================================
  # SessionsQueryService
  # =========================================================================

  test 'SessionsQueryService.list output matches sessions_index schema' do
    result = Analytics::SessionsQueryService.list(
      @project.id,
      start_date: 30.days.ago.to_date,
      end_date: Date.current
    )
    json = deep_stringify(result)
    assert_analytics_schema(:sessions_index, json)
    assert json['data'].size > 0, 'Expected non-empty session data'
    assert_each_analytics_item(:session_summary_item, json['data'])
  end

  test 'SessionsQueryService.find output matches sessions_show schema' do
    list = Analytics::SessionsQueryService.list(
      @project.id, start_date: 30.days.ago.to_date, end_date: Date.current
    )
    first = list[:data].first
    assert_not_nil first, 'Expected at least one session to detail'

    found = Analytics::SessionsQueryService.find(
      @project.id, session_id: first['session_id'], visitor_id: first['visitor_id'],
      event_date: first['event_date']
    )
    assert_not_nil found, 'Expected to find session by composite identity'
    json = deep_stringify(found)
    assert_analytics_schema(:sessions_show, json)
    # The detail session object must match the full session_summary_item shape.
    validate_analytics_object(json['session'], OUTPUT_SCHEMAS[:session_summary_item], path: 'session', strict: true)
    assert_each_analytics_item(:session_event_item, json['events']) if json['events'].any?
  end

  # =========================================================================
  # RetentionService
  # =========================================================================

  test 'RetentionService.summary output matches retention_summary schema' do
    result = Analytics::RetentionService.summary(@project.id)
    json = deep_stringify(result)
    assert_analytics_schema(:retention_summary, json)
    json['sparkline'].each do |point|
      validate_analytics_object(
        deep_stringify(point), OUTPUT_SCHEMAS[:sparkline_point],
        path: 'sparkline_point', strict: true
      )
    end
  end

  private

  # =========================================================================
  # Helpers
  # =========================================================================

  # Recursively convert symbol keys to string keys (schemas expect string keys
  # because that is what JSON.parse produces on the controller boundary).
  def deep_stringify(obj)
    JSON.parse(obj.to_json)
  end

  # =========================================================================
  # Test Data Seeding
  # =========================================================================
  # Seeds all CH tables with enough data for every service method to return
  # non-empty results. This runs once per test via setup (each test gets a
  # fresh truncated CH).

  def seed_all_test_data
    seed_events
    seed_session_events
    seed_session_summaries
    seed_user_profiles
    seed_visitor_daily
  end

  # Events table: diverse event types, platforms, sources, versions
  def seed_events
    rows = []
    6.times do |i|
      rows << {
        event_id: "schema_evt_#{i}_#{SecureRandom.hex(4)}",
        project_id: @project.id,
        event_type: %w[VIEW OPEN INSTALL VIEW OPEN APP_OPEN][i],
        event_name: %w[home_screen login_screen settings checkout home_screen profile][i],
        screen_name: %w[HomeScreen LoginScreen SettingsScreen CheckoutScreen HomeScreen ProfileScreen][i],
        visitor_id: 8000 + (i % 3),
        device_id: 9000 + (i % 3),
        platform: i < 4 ? 'ios' : 'android',
        app_version: i < 3 ? '1.0.0' : '2.0.0',
        country: 'US',
        city: 'New York',
        device_model: 'iPhone14,2',
        os: 'iOS',
        os_version: '17.0',
        tracking_source: i.zero? ? '' : 'campaign_1',
        tracking_medium: i.zero? ? '' : 'cpc',
        tracking_campaign: i.zero? ? '' : 'spring',
        sdk_identifier: 'com.test.ios',
        session_id: "schema_session_#{i / 2}",
        engagement_time: 5000 + (i * 100),
        created_at: (@now - i.hours).utc.strftime('%Y-%m-%d %H:%M:%S.%3N')
      }
    end
    insert_ch_events(rows)
  end

  # Session events: multiple sessions with screen sequences
  def seed_session_events
    rows = []
    3.times do |session_i|
      screens = %w[HomeScreen LoginScreen SettingsScreen ProfileScreen]
      screens.each_with_index do |screen, screen_i|
        rows << {
          project_id: @project.id,
          session_id: "schema_flow_session_#{session_i}",
          visitor_id: 8000 + session_i,
          device_id: 9000 + session_i,
          event_date: Date.current.to_s,
          event_type: 'screen_view',
          event_name: screen.underscore,
          screen_name: screen,
          platform: 'ios',
          app_version: '1.0.0',
          country: 'US',
          tracking_source: session_i.zero? ? '' : 'campaign_1',
          created_at: (@now - session_i.hours - (10 - screen_i).minutes).utc.strftime('%Y-%m-%d %H:%M:%S.%3N')
        }
      end
    end
    insert_ch_session_events(rows)
  end

  # Session summaries: read by SessionsQueryService
  def seed_session_summaries
    rows = 3.times.map do |i|
      {
        project_id: @project.id,
        session_id: "schema_flow_session_#{i}",
        visitor_id: 8000 + i,
        event_date: Date.current.to_s,
        platform: 'ios',
        app_version: '1.0.0',
        country: 'US',
        device_model: 'iPhone14,2',
        tracking_source: i.zero? ? '' : 'campaign_1',
        screen_count: 4,
        event_count: 6,
        duration_ms: 30_000 + (i * 5000),
        first_screen: 'HomeScreen',
        last_screen: 'ProfileScreen',
        has_conversion: i.even? ? 1 : 0,
        started_at: (@now - i.hours).utc.strftime('%Y-%m-%d %H:%M:%S.%3N'),
        ended_at: (@now - i.hours + 30.seconds).utc.strftime('%Y-%m-%d %H:%M:%S.%3N')
      }
    end
    insert_ch_session_summaries(rows)
  end

  # User profiles: for retention service
  def seed_user_profiles
    profiles = []
    10.times do |i|
      visitor_id = 8000 + i
      first_seen = (@now - (14 + i).days).utc.strftime('%Y-%m-%d %H:%M:%S.%3N')

      profiles << {
        project_id: @project.id,
        visitor_id: visitor_id,
        first_seen: first_seen,
        last_seen: (@now - i.days).utc.strftime('%Y-%m-%d %H:%M:%S.%3N'),
        platform: 'ios',
        country: 'US'
      }
    end
    insert_ch_user_profiles(profiles)
  end

  # Visitor daily: for retention calculations
  def seed_visitor_daily
    visitor_rows = []
    10.times do |i|
      visitor_id = 8000 + i
      first_seen_date = (@now - (14 + i).days).to_date

      # Day 1 return for half
      if i < 5
        visitor_rows << {
          project_id: @project.id,
          visitor_id: visitor_id,
          event_date: (first_seen_date + 1).to_s,
          event_type: 'OPEN',
          platform: 'ios',
          cnt: 1,
          total_engagement_time: 1000,
          inviter_id_state: 0
        }
      end

      # Day 7 return for a subset
      if i < 3
        visitor_rows << {
          project_id: @project.id,
          visitor_id: visitor_id,
          event_date: (first_seen_date + 7).to_s,
          event_type: 'OPEN',
          platform: 'ios',
          cnt: 1,
          total_engagement_time: 1500,
          inviter_id_state: 0
        }
      end

      # Recent activity so max_event_date is fresh
      visitor_rows << {
        project_id: @project.id,
        visitor_id: visitor_id,
        event_date: (@now - i.days).to_date.to_s,
        event_type: 'OPEN',
        platform: 'ios',
        cnt: 1,
        total_engagement_time: 2000,
        inviter_id_state: 0
      }
    end
    insert_ch_visitor_daily(visitor_rows)
  end
end
