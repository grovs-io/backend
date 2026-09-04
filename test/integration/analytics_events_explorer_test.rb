# frozen_string_literal: true

require 'test_helper'
require_relative 'auth_test_helper'
require_relative 'analytics_schema_helper'

class AnalyticsEventsExplorerTest < ActionDispatch::IntegrationTest
  include AuthTestHelper
  include AnalyticsSchemaHelper
  include ClickhouseTestHelper

  fixtures :instances, :users, :instance_roles, :projects, :devices, :visitors

  setup do
    @admin_user = users(:admin_user)
    @project = projects(:one)
    @headers = doorkeeper_headers_for(@admin_user)
  end

  # ── Auth & access ────────────────────────────────────────────────────

  test 'returns 401 without auth token' do
    Clickhouse.stub(:read_enabled?, true) do
      get "#{API_PREFIX}/projects/#{@project.id}/analytics/events", headers: api_headers
    end
    assert_response :unauthorized
  end

  test 'returns 403 for non-member project' do
    other_project = projects(:two)
    Clickhouse.stub(:read_enabled?, true) do
      get "#{API_PREFIX}/projects/#{other_project.id}/analytics/events", headers: @headers
    end
    assert_response :forbidden
  end

  test 'returns 503 with exact error body when CH disabled' do
    Clickhouse.stub(:read_enabled?, false) do
      get "#{API_PREFIX}/projects/#{@project.id}/analytics/events", headers: @headers
    end
    assert_response :service_unavailable
    assert_equal({ 'error' => 'Analytics temporarily unavailable' }, JSON.parse(response.body))
  end

  # ── GET /events (index) — param forwarding ──────────────────────────

  test 'index: forwards all params to service' do
    captured = nil
    fake = lambda { |*args, **kw| 
      captured = [args, kw]
      { data: [], next_cursor: nil, total_count: 0 }
    }
    valid_cursor = Base64.urlsafe_encode64({ t: '2026-05-01 00:00:00.000', id: 'evt_1' }.to_json, padding: false)

    with_ch_stub(::Analytics::EventsQueryService, :list, fake) do
      get "#{API_PREFIX}/projects/#{@project.id}/analytics/events",
          params: { start_date: '2026-04-01', end_date: '2026-05-01',
                    cursor: valid_cursor, limit: '25', sort_by: 'event_type',
                    sort_order: 'asc', search: 'login', include_count: 'true',
                    filters: '[{"field":"platform","operator":"is","value":"ios"}]' },
          headers: @headers
    end

    assert_response :ok
    assert_equal @project.id, captured[0][0]
    assert_equal Date.parse('2026-04-01'), captured[1][:start_date]
    assert_equal Date.parse('2026-05-01'), captured[1][:end_date]
    assert_equal valid_cursor, captured[1][:cursor]
    assert_equal 25, captured[1][:limit]
    assert_equal 'event_type', captured[1][:sort_by]
    assert_equal 'asc', captured[1][:sort_order]
    assert_equal 'login', captured[1][:search]
    assert_equal true, captured[1][:include_count]
    assert_equal '[{"field":"platform","operator":"is","value":"ios"}]', captured[1][:filters]
  end

  test 'index: uses defaults when optional params omitted' do
    captured = nil
    fake = lambda { |*args, **kw| 
      captured = [args, kw]
      { data: [], next_cursor: nil, total_count: nil }
    }

    with_ch_stub(::Analytics::EventsQueryService, :list, fake) do
      get "#{API_PREFIX}/projects/#{@project.id}/analytics/events", headers: @headers
    end

    assert_response :ok
    assert_equal 30.days.ago.to_date, captured[1][:start_date]
    assert_equal Date.current, captured[1][:end_date]
    assert_nil captured[1][:cursor]
    assert_equal 50, captured[1][:limit]
    assert_nil captured[1][:sort_by]
    assert_nil captured[1][:sort_order]
    assert_nil captured[1][:search]
    assert_nil captured[1][:filters]
    assert_equal false, captured[1][:include_count]
  end

  test 'index: malformed dates fall back to defaults' do
    captured = nil
    fake = lambda { |*args, **kw| 
      captured = [args, kw]
      { data: [], next_cursor: nil, total_count: nil }
    }

    with_ch_stub(::Analytics::EventsQueryService, :list, fake) do
      get "#{API_PREFIX}/projects/#{@project.id}/analytics/events",
          params: { start_date: 'not-a-date', end_date: 'garbage' },
          headers: @headers
    end

    assert_response :ok
    assert_equal 30.days.ago.to_date, captured[1][:start_date]
    assert_equal Date.current, captured[1][:end_date]
  end

  test 'index: forwards hostile-looking search string unchanged to service' do
    captured = nil
    fake = lambda { |*args, **kw| 
      captured = [args, kw]
      { data: [], next_cursor: nil, total_count: 0 }
    }

    with_ch_stub(::Analytics::EventsQueryService, :list, fake) do
      get "#{API_PREFIX}/projects/#{@project.id}/analytics/events",
          params: { search: "' OR 1=1 --" },
          headers: @headers
    end

    assert_response :ok
    assert_equal "' OR 1=1 --", captured[1][:search]
  end

  # ── GET /events (index) — passthrough integrity ─────────────────────

  # Rows gain visitor_uuid/resolved_visitor_id; everything else passes through untouched.
  test 'index: passes service result through, only annotating rows with visitor uuids' do
    canary = { canary_key: 'canary_value', data: [{ 'x' => 1 }], next_cursor: nil, total_count: 0 }

    with_ch_stub(::Analytics::EventsQueryService, :list, canary) do
      get "#{API_PREFIX}/projects/#{@project.id}/analytics/events",
          params: { start_date: '2026-04-01', end_date: '2026-05-01' },
          headers: @headers
    end

    assert_response :ok
    json = JSON.parse(response.body)
    assert_equal 'canary_value', json['canary_key']
    assert_nil json['next_cursor']
    assert_equal 0, json['total_count']
    assert_equal [{ 'x' => 1, 'visitor_uuid' => nil, 'resolved_visitor_id' => nil }], json['data']
  end

  test 'index: empty data — empty array, nil cursor, zero count' do
    stub_result = { data: [], next_cursor: nil, total_count: 0 }

    with_ch_stub(::Analytics::EventsQueryService, :list, stub_result) do
      get "#{API_PREFIX}/projects/#{@project.id}/analytics/events",
          params: { start_date: '2026-05-01', end_date: '2026-05-08' },
          headers: @headers
    end

    json = JSON.parse(response.body)
    assert_equal [], json['data']
    assert_nil json['next_cursor']
    assert_equal 0, json['total_count']
  end

  # ── GET /events (index) — error cases ───────────────────────────────

  # Was: any range > 90 days returned 422. The row-list cap is now relaxed to
  # MAX_RAW_EVENT_RANGE_DAYS (365), so a 200-day range that used to be rejected
  # now passes through to the service.
  test 'index: allows a 200-day range (row-list cap relaxed from 90 to 365)' do
    stub_result = { data: [], next_cursor: nil, total_count: nil }

    with_ch_stub(::Analytics::EventsQueryService, :list, stub_result) do
      get "#{API_PREFIX}/projects/#{@project.id}/analytics/events",
          params: { start_date: '2026-01-01', end_date: '2026-07-20' },
          headers: @headers
    end

    assert_response :ok
  end

  test 'index: exactly 90 days is allowed' do
    stub_result = { data: [], next_cursor: nil, total_count: nil }

    with_ch_stub(::Analytics::EventsQueryService, :list, stub_result) do
      get "#{API_PREFIX}/projects/#{@project.id}/analytics/events",
          params: { start_date: '2026-02-01', end_date: '2026-05-02' },
          headers: @headers
    end

    assert_response :ok
  end

  # Beyond the aggregate cap (90 days) the count is too heavy to run on the
  # un-rolled-up table, so the controller forces include_count=false (total_count
  # may be null per contract) even though the row-list range itself is allowed.
  test 'index: drops include_count when range exceeds the aggregate cap' do
    captured = nil
    fake = lambda { |*_args, **kw| 
      captured = kw
      { data: [], next_cursor: nil, total_count: nil }
    }

    with_ch_stub(::Analytics::EventsQueryService, :list, fake) do
      get "#{API_PREFIX}/projects/#{@project.id}/analytics/events",
          params: { start_date: '2026-01-01', end_date: '2026-07-20', include_count: 'true' },
          headers: @headers
    end

    assert_response :ok
    assert_equal false, captured[:include_count]
  end

  test 'index: keeps include_count when range is within the aggregate cap' do
    captured = nil
    fake = lambda { |*_args, **kw| 
      captured = kw
      { data: [], next_cursor: nil, total_count: 0 }
    }

    with_ch_stub(::Analytics::EventsQueryService, :list, fake) do
      get "#{API_PREFIX}/projects/#{@project.id}/analytics/events",
          params: { start_date: '2026-04-01', end_date: '2026-05-01', include_count: 'true' },
          headers: @headers
    end

    assert_response :ok
    assert_equal true, captured[:include_count]
  end

  test 'index: invalid cursor returns 400 with exact error' do
    stub_result = { data: nil, next_cursor: nil, total_count: nil }

    with_ch_stub(::Analytics::EventsQueryService, :list, stub_result) do
      get "#{API_PREFIX}/projects/#{@project.id}/analytics/events",
          params: { cursor: 'invalid-cursor' },
          headers: @headers
    end

    assert_response :bad_request
    assert_equal({ 'error' => 'Invalid cursor' }, JSON.parse(response.body))
  end

  test 'index: valid JSON cursor missing id returns 400' do
    cursor = Base64.urlsafe_encode64({ t: '2026-05-01 00:00:00.000' }.to_json, padding: false)

    Clickhouse.stub(:read_enabled?, true) do
      get "#{API_PREFIX}/projects/#{@project.id}/analytics/events",
          params: { cursor: cursor },
          headers: @headers
    end

    assert_response :bad_request
    assert_equal({ 'error' => 'Invalid cursor' }, JSON.parse(response.body))
  end

  # ── GET /events/:event_id (show) ────────────────────────────────────

  test 'show: forwards project_id and event_id to service' do
    captured = nil
    fake = lambda { |*args, **kw| 
      captured = [args, kw]
      nil
    }

    with_ch_stub(::Analytics::EventsQueryService, :find, fake) do
      get "#{API_PREFIX}/projects/#{@project.id}/analytics/events/evt_abc", headers: @headers
    end

    assert_response :not_found
    assert_equal @project.id, captured[0][0]
    assert_equal 'evt_abc', captured[1][:event_id]
  end

  test 'show: response schema — strict validation' do
    event = {
      'event_id' => 'abc123', 'project_id' => 1, 'event_type' => 'VIEW',
      'event_name' => 'page_view', 'screen_name' => 'Home', 'visitor_id' => 42,
      'device_id' => 1, 'link_id' => nil, 'campaign_id' => nil,
      'session_id' => 'sess1', 'platform' => 'ios', 'app_version' => '2.0.0',
      'device_model' => nil, 'os' => nil, 'os_version' => nil,
      'country' => nil, 'city' => nil, 'tracking_source' => nil,
      'tracking_medium' => nil, 'tracking_campaign' => nil,
      'ads_platform' => nil, 'sdk_identifier' => nil,
      'engagement_time' => nil, 'properties' => nil,
      'created_at' => '2026-05-01 10:00:00.000'
    }

    with_ch_stub(::Analytics::EventsQueryService, :find, event) do
      get "#{API_PREFIX}/projects/#{@project.id}/analytics/events/abc123", headers: @headers
    end

    assert_response :ok
    json = assert_analytics_schema(:event_show)
    assert_each_analytics_item(:event_item, [json['data']])
  end

  test 'show: returns 404 with exact error when not found' do
    with_ch_stub(::Analytics::EventsQueryService, :find, nil) do
      get "#{API_PREFIX}/projects/#{@project.id}/analytics/events/nonexistent", headers: @headers
    end
    assert_response :not_found
    assert_equal({ 'error' => 'Event not found' }, JSON.parse(response.body))
  end

  # ── GET /events/volume ──────────────────────────────────────────────

  test 'volume: forwards dates, bucket, search, filters to service' do
    captured = nil
    fake = lambda { |*args, **kw| 
      captured = [args, kw]
      { buckets: [] }
    }

    with_ch_stub(::Analytics::EventsQueryService, :volume, fake) do
      get "#{API_PREFIX}/projects/#{@project.id}/analytics/events/volume",
          params: { start_date: '2026-05-01', end_date: '2026-05-08',
                    bucket: 'hour', search: 'click' },
          headers: @headers
    end

    assert_response :ok
    assert_equal Date.parse('2026-05-01'), captured[1][:start_date]
    assert_equal Date.parse('2026-05-08'), captured[1][:end_date]
    assert_equal 'hour', captured[1][:bucket]
    assert_equal 'click', captured[1][:search]
    assert_nil captured[1][:filters]
  end

  test 'volume: controller passes service result through unchanged' do
    canary = { 'buckets' => [{ 'canary' => true }], 'extra_field' => 42 }

    with_ch_stub(::Analytics::EventsQueryService, :volume, canary) do
      get "#{API_PREFIX}/projects/#{@project.id}/analytics/events/volume",
          params: { start_date: '2026-05-01', end_date: '2026-05-08' },
          headers: @headers
    end

    assert_response :ok
    json = JSON.parse(response.body)
    assert_equal canary, json, 'Controller should pass service result through without modification'
  end

  test 'volume: returns 422 when date range exceeds the aggregate cap (90 days)' do
    # Recent range (within retention) but over the 90-day aggregate cap.
    Clickhouse.stub(:read_enabled?, true) do
      get "#{API_PREFIX}/projects/#{@project.id}/analytics/events/volume",
          params: { start_date: '2026-01-01', end_date: '2026-06-01' },
          headers: @headers
    end
    assert_response :unprocessable_entity
    json = assert_analytics_schema(:error_with_code)
    assert_equal 'Date range cannot exceed 90 days for this query', json['error']
    assert_equal 'query_too_heavy', json['error_code']
  end

  # The picker offers exactly queryable_days back, so a +03:00 viewer's local midnight is
  # the previous day in UTC — judging it as a UTC day puts it below the cutoff.
  test 'index: the oldest selectable day is not rejected for a non-UTC viewer' do
    zone = ActiveSupport::TimeZone['Europe/Bucharest']
    oldest = Date.current - ::Analytics::RetentionPolicy.for(@project.instance).queryable_days
    from = zone.local(oldest.year, oldest.month, oldest.day).utc.iso8601(3)
    to = zone.local(Date.current.year, Date.current.month, Date.current.day).utc.iso8601(3)

    with_ch_stub(::Analytics::EventsQueryService, :list,
                 { data: [], next_cursor: nil, total_count: 0 }) do
      get "#{API_PREFIX}/projects/#{@project.id}/analytics/events",
          params: { start_date: from, end_date: to, timezone: 'Europe/Bucharest' },
          headers: @headers
    end
    assert_response :ok
  end

  test 'volume: an exclusive-end instant range is capped on its last included day' do
    # The exclusive end names the day after the last included one, so both sides of the
    # 90-day cap must be pinned — passing only the allowed case would survive its deletion.
    ends_at = (Date.current + 1).to_time(:utc).iso8601(3)

    with_ch_stub(::Analytics::EventsQueryService, :volume, { buckets: [] }) do
      get "#{API_PREFIX}/projects/#{@project.id}/analytics/events/volume",
          params: { start_date: (Date.current - 90).to_time(:utc).iso8601(3), end_date: ends_at },
          headers: @headers
    end
    assert_response :ok

    with_ch_stub(::Analytics::EventsQueryService, :volume, { buckets: [] }) do
      get "#{API_PREFIX}/projects/#{@project.id}/analytics/events/volume",
          params: { start_date: (Date.current - 91).to_time(:utc).iso8601(3), end_date: ends_at },
          headers: @headers
    end
    assert_response :unprocessable_entity
    assert_equal 'query_too_heavy', JSON.parse(response.body)['error_code']
  end

  test 'volume: allows a range within the aggregate cap' do
    with_ch_stub(::Analytics::EventsQueryService, :volume, { buckets: [] }) do
      get "#{API_PREFIX}/projects/#{@project.id}/analytics/events/volume",
          params: { start_date: '2026-04-01', end_date: '2026-05-01' },
          headers: @headers
    end
    assert_response :ok
  end

  test 'volume: empty returns empty buckets' do
    with_ch_stub(::Analytics::EventsQueryService, :volume, { buckets: [] }) do
      get "#{API_PREFIX}/projects/#{@project.id}/analytics/events/volume",
          params: { start_date: '2026-05-01', end_date: '2026-05-08' },
          headers: @headers
    end
    assert_equal({ 'buckets' => [] }, JSON.parse(response.body))
  end

  # ── GET /events/field-values ────────────────────────────────────────

  test 'field_values: forwards field, q, limit to service' do
    captured = nil
    fake = lambda { |*args, **kw| 
      captured = [args, kw]
      { values: [] }
    }

    with_ch_stub(::Analytics::EventsQueryService, :field_values, fake) do
      get "#{API_PREFIX}/projects/#{@project.id}/analytics/events/field-values",
          params: { field: 'platform', q: 'io', limit: '10' },
          headers: @headers
    end

    assert_response :ok
    assert_equal 'platform', captured[1][:field]
    assert_equal 'io', captured[1][:q]
    assert_equal 10, captured[1][:limit]
  end

  test 'field_values: uses default limit=50 when not provided' do
    captured = nil
    fake = lambda { |*args, **kw| 
      captured = [args, kw]
      { values: [] }
    }

    with_ch_stub(::Analytics::EventsQueryService, :field_values, fake) do
      get "#{API_PREFIX}/projects/#{@project.id}/analytics/events/field-values",
          params: { field: 'event_type' },
          headers: @headers
    end

    assert_response :ok
    assert_equal 50, captured[1][:limit]
    assert_nil captured[1][:q]
  end

  test 'field_values: controller passes service result through unchanged' do
    canary = { 'values' => %w[ios android], 'canary_key' => 'present' }

    with_ch_stub(::Analytics::EventsQueryService, :field_values, canary) do
      get "#{API_PREFIX}/projects/#{@project.id}/analytics/events/field-values",
          params: { field: 'platform' },
          headers: @headers
    end

    assert_response :ok
    json = JSON.parse(response.body)
    assert_equal canary, json, 'Controller should pass service result through without modification'
  end

  test 'field_values: accepts a user.-prefixed attribute key' do
    captured = nil
    fake = lambda { |*args, **kw|
      captured = [args, kw]
      { values: [] }
    }

    with_ch_stub(::Analytics::EventsQueryService, :field_values, fake) do
      get "#{API_PREFIX}/projects/#{@project.id}/analytics/events/field-values",
          params: { field: 'user.plan' },
          headers: @headers
    end

    assert_response :ok
    assert_equal 'user.plan', captured[1][:field]
  end

  test 'field_values: rejects a user.-prefixed key with an invalid suffix' do
    Clickhouse.stub(:read_enabled?, true) do
      get "#{API_PREFIX}/projects/#{@project.id}/analytics/events/field-values",
          params: { field: 'user.bad`key' },
          headers: @headers
    end
    assert_response :bad_request
  end

  test 'field_values: plain non-allowlisted field still rejected' do
    Clickhouse.stub(:read_enabled?, true) do
      get "#{API_PREFIX}/projects/#{@project.id}/analytics/events/field-values",
          params: { field: 'plan' },
          headers: @headers
    end
    assert_response :bad_request
  end

  test 'field_values: returns 400 with exact error when field param missing' do
    Clickhouse.stub(:read_enabled?, true) do
      get "#{API_PREFIX}/projects/#{@project.id}/analytics/events/field-values",
          headers: @headers
    end
    assert_response :bad_request
    assert_equal({ 'error' => 'field parameter is required' }, JSON.parse(response.body))
  end

  # ── GET /events/fields ──────────────────────────────────────────────

  test 'fields: forwards project_id to service' do
    captured = nil
    fake = lambda { |*args, **kw| 
      captured = [args, kw]
      { fields: [] }
    }

    with_ch_stub(::Analytics::EventsQueryService, :fields, fake) do
      get "#{API_PREFIX}/projects/#{@project.id}/analytics/events/fields", headers: @headers
    end

    assert_response :ok
    assert_equal @project.id, captured[0][0]
  end

  test 'fields: controller passes service result through unchanged' do
    canary = { 'fields' => [{ 'name' => 'canary', 'type' => 'attribute' }], 'extra' => true }

    with_ch_stub(::Analytics::EventsQueryService, :fields, canary) do
      get "#{API_PREFIX}/projects/#{@project.id}/analytics/events/fields", headers: @headers
    end

    assert_response :ok
    json = JSON.parse(response.body)
    assert_equal canary, json, 'Controller should pass service result through without modification'
  end

  # ── Error response schema validation ────────────────────────────────

  # Far-back start is rejected by the retention gate before the raw-list cap.
  test 'index: rejects a range reaching past the plan retention window' do
    # Start older than even the paid window (>730d) so retention fires for any plan.
    Clickhouse.stub(:read_enabled?, true) do
      get "#{API_PREFIX}/projects/#{@project.id}/analytics/events",
          params: { start_date: '2024-01-01', end_date: '2026-06-01' },
          headers: @headers
    end
    assert_response :unprocessable_entity
    json = assert_analytics_schema(:error_with_code)
    assert_equal 'retention_window_exceeded', json['error_code']
  end

  # Raw-list cap is the plan's queryable window: enterprise can exceed the 730 paid ceiling.
  test 'index: enterprise can pull a raw list beyond the paid window' do
    @project.instance.update!(cold_storage_days: 365, delete_days: 1825)
    EnterpriseSubscription.create!(instance: @project.instance, active: true,
                                   total_maus: 100_000, start_date: 3.years.ago, end_date: 1.year.from_now)
    Clickhouse.stub(:read_enabled?, true) do
      get "#{API_PREFIX}/projects/#{@project.id}/analytics/events",
          params: { start_date: (Date.current - 1000).to_s, end_date: Date.current.to_s },
          headers: @headers
    end
    code = JSON.parse(response.body)['error_code'] rescue nil
    assert_not_equal 'query_too_heavy', code
    assert_not_equal 'retention_window_exceeded', code
  end

  test 'show: 404 error schema is strict' do
    with_ch_stub(::Analytics::EventsQueryService, :find, nil) do
      get "#{API_PREFIX}/projects/#{@project.id}/analytics/events/nonexistent", headers: @headers
    end
    assert_response :not_found
    assert_analytics_schema(:error_response)
  end

  test 'field_values: 400 error schema is strict' do
    Clickhouse.stub(:read_enabled?, true) do
      get "#{API_PREFIX}/projects/#{@project.id}/analytics/events/field-values",
          headers: @headers
    end
    assert_response :bad_request
    assert_analytics_schema(:error_response)
  end

  # ── Invalid input validation ───────────────────────────────────────

  test 'index: invalid sort_by returns 400' do
    Clickhouse.stub(:read_enabled?, true) do
      get "#{API_PREFIX}/projects/#{@project.id}/analytics/events",
          params: { sort_by: 'malicious_field' },
          headers: @headers
    end
    assert_response :bad_request
    json = JSON.parse(response.body)
    assert json['error'].include?('sort_by')
  end

  test 'index: invalid sort_order returns 400' do
    Clickhouse.stub(:read_enabled?, true) do
      get "#{API_PREFIX}/projects/#{@project.id}/analytics/events",
          params: { sort_order: 'sideways' },
          headers: @headers
    end
    assert_response :bad_request
    json = JSON.parse(response.body)
    assert json['error'].include?('sort_order')
  end

  test 'index: non-integer limit falls back to default' do
    captured = nil
    fake = lambda { |*args, **kw| 
      captured = [args, kw]
      { data: [], next_cursor: nil, total_count: nil }
    }

    with_ch_stub(::Analytics::EventsQueryService, :list, fake) do
      get "#{API_PREFIX}/projects/#{@project.id}/analytics/events",
          params: { limit: 'not_a_number' },
          headers: @headers
    end

    assert_response :ok
    assert_equal 50, captured[1][:limit]
  end

  test 'volume: invalid bucket returns 400' do
    Clickhouse.stub(:read_enabled?, true) do
      get "#{API_PREFIX}/projects/#{@project.id}/analytics/events/volume",
          params: { start_date: '2026-05-01', end_date: '2026-05-08', bucket: 'millennium' },
          headers: @headers
    end
    assert_response :bad_request
    json = JSON.parse(response.body)
    assert json['error'].include?('bucket')
  end

  test 'field_values: non-integer limit falls back to default' do
    captured = nil
    fake = lambda { |*args, **kw| 
      captured = [args, kw]
      { values: [] }
    }

    with_ch_stub(::Analytics::EventsQueryService, :field_values, fake) do
      get "#{API_PREFIX}/projects/#{@project.id}/analytics/events/field-values",
          params: { field: 'platform', limit: 'abc' },
          headers: @headers
    end

    assert_response :ok
    assert_equal 50, captured[1][:limit]
  end

  # ── QueryTooHeavy → 422 query_too_heavy (centralized in BaseController) ──

  test 'maps QueryTooHeavy to 422 query_too_heavy envelope' do
    raise_heavy = ->(*_a, **_k) { raise ::Analytics::QueryTooHeavy, 'too big' }
    Clickhouse.stub(:read_enabled?, true) do
      ::Analytics::EventsQueryService.stub(:list, raise_heavy) do
        get "#{API_PREFIX}/projects/#{@project.id}/analytics/events", headers: @headers
      end
    end
    assert_response :unprocessable_entity
    body = assert_analytics_schema(:error_with_code)
    assert_equal 'query_too_heavy', body['error_code']
    assert body['error'].present?
  end

  # Proves the rescue_from lives on the shared BaseController, not just the events
  # controller: a DIFFERENT analytics endpoint (overview) whose service raises
  # QueryTooHeavy also yields the same 422 envelope.
  test 'maps QueryTooHeavy to 422 on a different analytics controller (overview)' do
    raise_heavy = ->(*_a, **_k) { raise ::Analytics::QueryTooHeavy, 'too big' }
    Clickhouse.stub(:read_enabled?, true) do
      ::Analytics::OverviewStatsService.stub(:versions, raise_heavy) do
        get "#{API_PREFIX}/projects/#{@project.id}/analytics/overview/versions", headers: @headers
      end
    end
    assert_response :unprocessable_entity
    body = assert_analytics_schema(:error_with_code)
    assert_equal 'query_too_heavy', body['error_code']
    assert body['error'].present?
  end

  # A non-heavy failure raised *inside* the real `list` execution must be swallowed by
  # its outer `rescue StandardError => e; log_query_failure` into the normal empty 200
  # shape — NOT mis-mapped to 422. We stub the low-level guard so a genuine, non-heavy
  # DatabaseError (an unknown-identifier bug, not a timeout/memory cap) is raised while
  # the real `list` runs; the controller must still return 200 with `data: []`.
  test 'non-heavy DatabaseError inside list is swallowed into the normal empty 200 shape' do
    non_heavy = lambda { |_sql|
      raise ClickHouse::Client::DatabaseError, 'Code: 47. DB::Exception: Unknown identifier foo'
    }
    Clickhouse.stub(:read_enabled?, true) do
      ::Analytics::EventsQueryService.stub(:with_guard, non_heavy) do
        get "#{API_PREFIX}/projects/#{@project.id}/analytics/events",
            params: { include_count: 'true' }, headers: @headers
      end
    end
    assert_response :ok
    json = JSON.parse(response.body)
    assert_equal [], json['data']
    assert_nil json['next_cursor']
    assert_equal 0, json['total_count']
  end

  # End-to-end count degradation at the HTTP layer: a real data row is returned while
  # the count query is forced heavy. The endpoint must still answer 200 with the rows
  # present and total_count serialized as JSON null (degraded), never a 422.
  test 'count degradation returns 200 with rows and total_count null over HTTP' do
    skip_unless_clickhouse!
    insert_ch_events([{ event_id: 'http_count_degrade', project_id: @project.id,
                        event_type: 'OPEN', created_at: '2026-06-01 00:00:00.000' }])

    real = ::Analytics::EventsQueryService.method(:with_guard)
    count_heavy = lambda { |sql|
      raise ::Analytics::QueryTooHeavy, 'count too heavy' if sql.include?('count()')

      real.call(sql)
    }

    Clickhouse.stub(:read_enabled?, true) do
      ::Analytics::EventsQueryService.stub(:with_guard, count_heavy) do
        get "#{API_PREFIX}/projects/#{@project.id}/analytics/events",
            params: { start_date: '2026-06-01', end_date: '2026-06-02', include_count: 'true' },
            headers: @headers
      end
    end

    assert_response :ok
    json = JSON.parse(response.body)
    assert_not_empty json['data']
    assert_equal 'http_count_degrade', json['data'].first['event_id']
    assert_nil json['total_count'], 'degraded count must serialize as JSON null'
  end

  private

  # Also stubs uuid resolution: the controller runs it after the stubbed query, and an
  # unprovisioned CH database would otherwise 500 depending on test order.
  def with_ch_stub(service, method, result, &block)
    Clickhouse.stub(:read_enabled?, true) do
      ::Analytics::VisitorUuidResolver.stub(:resolve_many, {}) do
        service.stub(method, result, &block)
      end
    end
  end
end
