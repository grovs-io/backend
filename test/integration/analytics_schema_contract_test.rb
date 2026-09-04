# frozen_string_literal: true

require 'test_helper'
require_relative 'analytics_schema_helper'
require_relative 'auth_test_helper'

class AnalyticsSchemaContractTest < ActionDispatch::IntegrationTest
  include AuthTestHelper
  include AnalyticsSchemaHelper

  fixtures :instances, :users, :instance_roles, :projects

  setup do
    @admin_user = users(:admin_user)
    @project = projects(:one)
    @headers = doorkeeper_headers_for(@admin_user)
  end

  # ── Schema helper self-tests ─────────────────────────────────────────

  test 'strict mode catches unexpected extra key' do
    stub_result = {
      data: [],
      next_cursor: nil,
      total_count: 0,
      bonus_field: 'should not be here'
    }

    with_ch_stub(::Analytics::EventsQueryService, :list, stub_result) do
      get "#{API_PREFIX}/projects/#{@project.id}/analytics/events",
          params: { start_date: '2026-05-01', end_date: '2026-05-08' },
          headers: @headers
    end

    assert_response :ok
    error = assert_raises(Minitest::Assertion) do
      assert_analytics_schema(:events_index)
    end
    assert_match(/unexpected keys.*bonus_field/, error.message)
  end

  test 'strict mode catches missing required key' do
    stub_result = {
      next_cursor: nil,
      total_count: 0
      # "data" is missing
    }

    with_ch_stub(::Analytics::EventsQueryService, :list, stub_result) do
      get "#{API_PREFIX}/projects/#{@project.id}/analytics/events",
          params: { start_date: '2026-05-01', end_date: '2026-05-08' },
          headers: @headers
    end

    assert_response :ok
    error = assert_raises(Minitest::Assertion) do
      assert_analytics_schema(:events_index)
    end
    assert_match(/missing required key 'data'/, error.message)
  end

  test 'strict mode catches wrong type' do
    stub_result = {
      data: 'not an array',
      next_cursor: nil,
      total_count: 0
    }

    with_ch_stub(::Analytics::EventsQueryService, :list, stub_result) do
      get "#{API_PREFIX}/projects/#{@project.id}/analytics/events",
          params: { start_date: '2026-05-01', end_date: '2026-05-08' },
          headers: @headers
    end

    assert_response :ok
    error = assert_raises(Minitest::Assertion) do
      assert_analytics_schema(:events_index)
    end
    assert_match(/expected Array/, error.message)
  end

  # ── Coverage completeness checks ─────────────────────────────────────

  # Verify every OUTPUT_SCHEMA is actually used in a validation call.
  # Matches assert_analytics_schema(:name), assert_each_analytics_item(:name),
  # and OUTPUT_SCHEMAS[:name] (for sub-schemas used via validate_analytics_object).
  test 'every output schema has a validation call' do
    test_files = Dir.glob(Rails.root.join("test/**/*.rb"))
    test_contents = test_files.map { |f| File.read(f) }.join

    # Matches: assert_analytics_schema(:foo), assert_each_analytics_item(:foo), OUTPUT_SCHEMAS[:foo]
    usage_pattern = /(?:assert_(?:analytics_schema|each_analytics_item)\(\s*:|OUTPUT_SCHEMAS\[\s*:)(\w+)/
    used_schemas = test_contents.scan(usage_pattern).flatten.map(&:to_sym).uniq

    OUTPUT_SCHEMAS.each_key do |schema_name|
      assert_includes used_schemas, schema_name,
                      "OUTPUT_SCHEMAS[:#{schema_name}] is defined but never used in any test. " \
                      'Add assert_analytics_schema, assert_each_analytics_item, or OUTPUT_SCHEMAS[:name] usage.'
    end
  end

  # Verify every INPUT_SCHEMA strict enum (ones that SHOULD reject bad input)
  # has at least one invalid-value test. Excludes "platform" since invalid
  # platforms just filter to empty results (not a 400).
  SOFT_ENUMS = %w[platform].freeze

  test 'every strict INPUT_SCHEMA enum has an invalid-input test' do
    test_files = Dir.glob(Rails.root.join("test/integration/analytics_*.rb"))
    test_contents = test_files.map { |f| File.read(f) }.join

    INPUT_SCHEMAS.each do |endpoint, schema|
      next unless schema[:enums]

      schema[:enums].each_key do |param_name|
        next if SOFT_ENUMS.include?(param_name)

        has_test = test_contents.match?(/#{param_name}.*(?:invalid|bad|returns 400|malicious)/i) ||
                   test_contents.match?(/validate_enum!.*#{param_name}/i)
        assert has_test,
               "INPUT_SCHEMAS[:#{endpoint}][:enums][\"#{param_name}\"] has no invalid-input test. " \
               "Add a test that sends an invalid #{param_name} and asserts 400."
      end
    end
  end

  # Verify every analytics route in routes.rb has at least one integration test.
  test 'every analytics route has integration test coverage' do
    test_files = Dir.glob(Rails.root.join("test/integration/analytics_*.rb"))
    test_contents = test_files.map { |f| File.read(f) }.join

    # All analytics route paths from routes.rb
    routes = %w[
      analytics/events
      analytics/events/volume
      analytics/events/field-values
      analytics/events/fields
      analytics/overview/key-metrics
      analytics/overview/key-metrics/series
      analytics/overview/versions
      analytics/overview/versions/distribution
      analytics/overview/trends/users
      analytics/overview/sources/breakdown
      analytics/retention/summary
      analytics/sessions
    ]

    routes.each do |route|
      # Normalize hyphens for test file matching
      pattern = route.gsub('-', '[-_]')
      has_test = test_contents.match?(/#{Regexp.escape(route)}|#{pattern}/i)
      assert has_test,
             "Route '#{route}' has no integration test. Add at least one test covering this endpoint."
    end
  end

  # ── Output schema ↔ service method mapping ─────────────────────────

  # Every OUTPUT_SCHEMA key that represents a top-level response (not sub-item
  # schemas like event_item, flow_node, etc.) must correspond to an actual
  # service method or controller action. This catches orphaned schemas that
  # no longer match any endpoint.
  SCHEMA_TO_SERVICE = {
    events_index:           [::Analytics::EventsQueryService, :list],
    event_show:             [::Analytics::EventsQueryService, :find],
    events_volume:          [::Analytics::EventsQueryService, :volume],
    events_field_values:    [::Analytics::EventsQueryService, :field_values],
    events_fields:          [::Analytics::EventsQueryService, :fields],
    overview_key_metrics:   [::Analytics::OverviewStatsService, :key_metrics],
    overview_key_metric_series: [::Analytics::OverviewStatsService, :key_metric_series],
    overview_versions:      [::Analytics::OverviewStatsService, :versions],
    user_trends:            [::Analytics::OverviewStatsService, :user_trends],
    sources_breakdown:      [::Analytics::OverviewStatsService, :sources_breakdown],
    version_distribution:   [::Analytics::OverviewStatsService, :version_distribution],
    sessions_index:         [::Analytics::SessionsQueryService, :list],
    sessions_show:          [::Analytics::SessionsQueryService, :find],
    retention_summary:      [::Analytics::RetentionService, :summary]
  }.freeze

  test 'every top-level OUTPUT_SCHEMA key maps to an existing service method' do
    SCHEMA_TO_SERVICE.each do |schema_key, (service_mod, method_name)|
      assert OUTPUT_SCHEMAS.key?(schema_key),
             "SCHEMA_TO_SERVICE references :#{schema_key} but OUTPUT_SCHEMAS does not define it"
      assert service_mod.respond_to?(method_name),
             "OUTPUT_SCHEMAS[:#{schema_key}] maps to #{service_mod}.#{method_name} but that method does not exist"
    end
  end

  # ── Input schema ↔ controller action mapping ───────────────────────

  # Every INPUT_SCHEMA key must map to a real controller action.
  INPUT_SCHEMA_TO_ACTION = {
    events_index:               [Api::V1::Analytics::EventsExplorerController, :index],
    events_show:                [Api::V1::Analytics::EventsExplorerController, :show],
    events_volume:              [Api::V1::Analytics::EventsExplorerController, :volume],
    events_field_values:        [Api::V1::Analytics::EventsExplorerController, :field_values],
    events_fields:              [Api::V1::Analytics::EventsExplorerController, :fields],
    overview_key_metrics:       [Api::V1::Analytics::OverviewController, :key_metrics],
    overview_key_metric_series: [Api::V1::Analytics::OverviewController, :key_metric_series],
    overview_versions:          [Api::V1::Analytics::OverviewController, :versions],
    overview_version_distribution: [Api::V1::Analytics::OverviewController, :version_distribution],
    overview_user_trends:       [Api::V1::Analytics::OverviewController, :user_trends],
    overview_sources_breakdown: [Api::V1::Analytics::OverviewController, :sources_breakdown],
    sessions_index:             [Api::V1::Analytics::SessionsController, :index],
    sessions_show:              [Api::V1::Analytics::SessionsController, :show],
    retention_summary:          [Api::V1::Analytics::RetentionController, :summary]
  }.freeze

  test 'every INPUT_SCHEMA key maps to an existing controller action' do
    INPUT_SCHEMA_TO_ACTION.each do |schema_key, (controller_class, action_name)|
      assert INPUT_SCHEMAS.key?(schema_key),
             "INPUT_SCHEMA_TO_ACTION references :#{schema_key} but INPUT_SCHEMAS does not define it"
      assert controller_class.instance_method(action_name),
             "INPUT_SCHEMAS[:#{schema_key}] maps to #{controller_class}##{action_name} but that action does not exist"
    end
  end

  # ── Stubbed response shape validation per endpoint ─────────────────

  # For each major endpoint, a realistic stubbed response is validated against
  # the strict output schema. This ensures schemas track what services return.

  test 'events index stubbed response passes strict schema validation' do
    stub_result = {
      data: [
        { 'event_id' => 'evt_1', 'project_id' => 1, 'event_type' => 'OPEN',
          'event_name' => '', 'screen_name' => 'HomeScreen', 'visitor_id' => 100,
          'device_id' => 10, 'link_id' => nil, 'campaign_id' => nil,
          'session_id' => 'sess_1', 'platform' => 'ios', 'app_version' => '2.0',
          'device_model' => 'iPhone14,2', 'os' => 'iOS', 'os_version' => '17.0',
          'country' => 'US', 'city' => 'New York',
          'tracking_source' => '', 'tracking_medium' => '', 'tracking_campaign' => '',
          'ads_platform' => '', 'sdk_identifier' => 'ios-sdk-1.0',
          'engagement_time' => 0, 'properties' => nil,
          'created_at' => '2026-05-01 12:00:00.000' }
      ],
      next_cursor: nil,
      total_count: 1
    }

    with_ch_stub(::Analytics::EventsQueryService, :list, stub_result) do
      get "#{API_PREFIX}/projects/#{@project.id}/analytics/events",
          params: { start_date: '2026-05-01', end_date: '2026-05-08', include_count: 'true' },
          headers: @headers
    end

    assert_response :ok
    json = assert_analytics_schema(:events_index)
    assert_each_analytics_item(:event_item, json['data'])
  end

  test 'sessions index stubbed response passes strict schema validation' do
    stub_result = {
      data: [
        { 'session_id' => 'sess_1', 'visitor_id' => 100, 'event_date' => '2026-05-01',
          'started_at' => '2026-05-01 10:00:00.000',
          'ended_at' => '2026-05-01 10:00:45.000', 'duration_ms' => 45_000, 'event_count' => 8,
          'platform' => 'ios', 'app_version' => '2.0', 'country' => 'US', 'device_model' => 'iPhone14,2',
          'link_id' => nil, 'campaign_id' => nil, 'tracking_source' => '', 'has_conversion' => 1,
          'revenue_usd_cents' => 0, 'source' => 'organic', 'id' => 'opaque_key_1' }
      ],
      next_cursor: nil
    }

    with_ch_stub(::Analytics::SessionsQueryService, :list, stub_result) do
      get "#{API_PREFIX}/projects/#{@project.id}/analytics/sessions",
          params: { start_date: '2026-05-01', end_date: '2026-05-08' },
          headers: @headers
    end

    assert_response :ok
    json = assert_analytics_schema(:sessions_index)
    assert_each_analytics_item(:session_summary_item, json['data'])
  end

  test 'sessions show stubbed response passes strict schema validation' do
    # Detail `session` carries the full LIST_COLUMNS + source + event_date, but NOT
    # the injected `id` (that's a list-row affordance). Validated strictly below.
    stub_result = {
      session: { 'session_id' => 'sess_1', 'visitor_id' => 100, 'event_date' => '2026-05-01',
                 'started_at' => '2026-05-01 10:00:00.000', 'ended_at' => '2026-05-01 10:00:45.000',
                 'duration_ms' => 45_000, 'event_count' => 8, 'platform' => 'ios', 'app_version' => '2.0',
                 'country' => 'US', 'device_model' => 'iPhone14,2', 'link_id' => nil, 'campaign_id' => nil,
                 'tracking_source' => '', 'has_conversion' => 1, 'revenue_usd_cents' => 0, 'source' => 'organic' },
      events: [
        { 'event_id' => 'evt_1', 'event_type' => 'OPEN', 'event_name' => '', 'screen_name' => 'HomeScreen',
          'created_at' => '2026-05-01 10:00:00.000', 'platform' => 'ios', 'app_version' => '2.0',
          'country' => 'US', 'link_id' => nil, 'campaign_id' => nil, 'engagement_time' => 0 }
      ]
    }
    key = ::Analytics::SessionsQueryService.encode_key('sess_1', 100, '2026-05-01')

    with_ch_stub(::Analytics::SessionsQueryService, :find, stub_result) do
      get "#{API_PREFIX}/projects/#{@project.id}/analytics/sessions/#{key}",
          headers: @headers
    end

    assert_response :ok
    json = assert_analytics_schema(:sessions_show)
    # Tighten: the detail session object must match the full session_summary_item shape.
    validate_analytics_object(json['session'], OUTPUT_SCHEMAS[:session_summary_item], path: 'session', strict: true)
    assert_each_analytics_item(:session_event_item, json['events'])
  end

  test 'retention summary stubbed response passes strict schema validation' do
    stub_result = {
      day_1: 80.0,
      day_7: 75.0,
      day_30: nil,
      sparkline: [{ 'date' => '2026-04-30', 'rate' => 80.0 }],
      median_churn_day: 5
    }

    with_ch_stub(::Analytics::RetentionService, :summary, stub_result) do
      get "#{API_PREFIX}/projects/#{@project.id}/analytics/retention/summary",
          headers: @headers
    end

    assert_response :ok
    json = assert_analytics_schema(:retention_summary)
    assert_each_analytics_item(:sparkline_point, json['sparkline'])
  end

  # ── Input parameter validation contracts ────────────────────────────

  # sanitize_string escapes backslash and single quotes to prevent injection.
  test 'sanitize_string escapes CH special characters' do
    helper = Class.new do 
      extend Analytics::QueryHelpers
      public_class_method :sanitize_string
    end
    # Single quote must be escaped
    assert_equal "\\'", helper.sanitize_string("'")
    # Backslash must be escaped
    assert_equal '\\\\', helper.sanitize_string('\\')
    # Null byte must be escaped
    assert_equal '\\0', helper.sanitize_string("\0")
    # Combined: O'Brien\ => O\\'Brien\\
    assert_equal "O\\'Brien\\\\", helper.sanitize_string("O'Brien\\")
    # Plain string passes through unchanged
    assert_equal 'hello', helper.sanitize_string('hello')
  end

  # sanitize_date rejects garbage and returns YYYY-MM-DD.
  test 'sanitize_date rejects invalid dates and normalizes valid ones' do
    helper = Class.new do 
      extend Analytics::QueryHelpers
      public_class_method :sanitize_date
    end
    # Valid ISO date
    assert_equal '2026-05-01', helper.sanitize_date('2026-05-01')
    # Alternate format normalizes
    assert_equal '2026-05-01', helper.sanitize_date('May 1, 2026')
    # Garbage raises Date::Error
    assert_raises(Date::Error) { helper.sanitize_date('not-a-date') }
  end

  # sanitize_like escapes % and _ so they are literal in LIKE patterns.
  test 'sanitize_like escapes LIKE wildcards' do
    helper = Class.new do 
      extend Analytics::QueryHelpers
      public_class_method :sanitize_like
    end
    # % becomes escaped (double-backslash for CH string literal)
    escaped = helper.sanitize_like('100%_off')
    assert_includes escaped, '\\\\%'
    assert_includes escaped, '\\\\_'
    # Regular characters unchanged
    assert_equal 'hello', helper.sanitize_like('hello')
  end

  # ── Date range boundary enforcement ─────────────────────────────────

  test 'events index rejects a range reaching past the plan retention window' do
    # Start older than even the paid window (>730d) so retention fires for any plan.
    Clickhouse.stub(:read_enabled?, true) do
      get "#{API_PREFIX}/projects/#{@project.id}/analytics/events",
          params: { start_date: '2024-01-01', end_date: '2026-06-01' },
          headers: @headers
    end

    assert_response :unprocessable_entity
    json = JSON.parse(response.body)
    assert_equal 'retention_window_exceeded', json['error_code']
    assert_analytics_schema(:error_with_code, json)
  end

  test 'events volume rejects date range exceeding MAX_AGGREGATE_RANGE_DAYS (90)' do
    # Aggregate cap held at 90 until rollups land (design §5); volume over-cap now
    # carries the query_too_heavy machine code.
    Clickhouse.stub(:read_enabled?, true) do
      get "#{API_PREFIX}/projects/#{@project.id}/analytics/events/volume",
          params: { start_date: '2026-01-01', end_date: '2026-05-01' },
          headers: @headers
    end

    assert_response :unprocessable_entity
    json = JSON.parse(response.body)
    assert_match(/cannot exceed 90 days/, json['error'])
    assert_equal 'query_too_heavy', json['error_code']
    assert_analytics_schema(:error_with_code, json)
  end

  # ── Pagination defaults within bounds ───────────────────────────────

  test 'pagination defaults are within INPUT_SCHEMA integer_ranges' do
    INPUT_SCHEMAS.each do |endpoint, schema|
      next unless schema[:integer_ranges]

      schema[:integer_ranges].each do |param, range|
        # Verify the range itself is sane (min >= 1, max reasonable)
        assert range.min >= 1,
               "INPUT_SCHEMAS[:#{endpoint}][:integer_ranges][\"#{param}\"] min #{range.min} should be >= 1"
        assert range.max <= 10_000,
               "INPUT_SCHEMAS[:#{endpoint}][:integer_ranges][\"#{param}\"] max #{range.max} is suspiciously large"
      end
    end
  end

  # ── CH table schema matches expected columns ────────────────────────

  # Verify that the migration DDL files define the columns we expect
  # for the core analytics tables. This catches column renames/removals
  # that would break service queries. Reads migration files directly
  # rather than depending on any schema constant.

  EXPECTED_EVENTS_COLUMNS = %w[
    event_id project_id event_type event_name screen_name
    device_id visitor_id link_id inviter_id campaign_id
    platform app_version build vendor_id device_model os os_version timezone language
    country city
    tracking_source tracking_medium tracking_campaign ads_platform link_tags
    sdk_identifier sdk_attributes
    session_id engagement_time properties tags
    ip remote_ip path created_at
  ].freeze

  EXPECTED_SESSION_SUMMARY_COLUMNS = %w[
    project_id session_id visitor_id event_date platform app_version
    country device_model tracking_source link_id campaign_id
    screen_count event_count duration_ms first_screen last_screen
    has_conversion revenue_usd_cents started_at ended_at
  ].freeze

  EXPECTED_USER_PROFILES_COLUMNS = %w[
    project_id visitor_id sdk_identifier properties
    first_seen last_seen country platform inviter_id
  ].freeze

  MIGRATIONS_PATH = Rails.root.join("db/clickhouse/migrate").freeze

  test 'events migration DDL defines all expected columns' do
    file = find_migration('create_events')
    ddl = File.read(file)
    EXPECTED_EVENTS_COLUMNS.each do |col|
      assert_match(/^\s+#{Regexp.escape(col)}\s/m, ddl,
                   "events migration (#{File.basename(file)}) is missing column '#{col}'")
    end
  end

  test 'session_summary migration DDL defines all expected columns' do
    file = find_migration('create_session_summary')
    ddl = File.read(file)
    EXPECTED_SESSION_SUMMARY_COLUMNS.each do |col|
      assert_match(/^\s+#{Regexp.escape(col)}\s/m, ddl,
                   "session_summary migration (#{File.basename(file)}) is missing column '#{col}'")
    end
  end

  test 'user_profiles migration DDL defines all expected columns' do
    file = find_migration('create_user_profiles')
    ddl = File.read(file)
    EXPECTED_USER_PROFILES_COLUMNS.each do |col|
      assert_match(/^\s+#{Regexp.escape(col)}\s/m, ddl,
                   "user_profiles migration (#{File.basename(file)}) is missing column '#{col}'")
    end
  end

  # ── Additional stubbed response shape tests (Fix #4) ─────────────────
  # Validates sub-item schemas for endpoints not covered by the original
  # 4 stubbed tests. Uses realistic fake data so that item-level schema
  # validation runs without ClickHouse.

  test 'user_trends stubbed response validates trend_point items' do
    stub_result = {
      points: [
        { 'date' => '2026-05-01', 'new_users' => 42, 'previous_new_users' => 30, 'users' => 42, 'previous_users' => 30, 'revenue_usd_cents' => 4299, 'previous_revenue_usd_cents' => 3100 },
        { 'date' => '2026-05-02', 'new_users' => 55, 'previous_new_users' => 40, 'users' => 55, 'previous_users' => 40, 'revenue_usd_cents' => 0, 'previous_revenue_usd_cents' => 0 }
      ]
    }

    with_ch_stub(::Analytics::OverviewStatsService, :user_trends, stub_result) do
      get "#{API_PREFIX}/projects/#{@project.id}/analytics/overview/trends/users",
          headers: @headers
    end

    assert_response :ok
    json = assert_analytics_schema(:user_trends)
    assert_each_analytics_item(:trend_point, json['points'])
  end

  test 'sources_breakdown stubbed response validates source_item items' do
    stub_result = {
      sources: [
        { 'name' => 'Organic', 'value' => 100 },
        { 'name' => 'Campaigns', 'value' => 50 }
      ],
      total: 150
    }

    with_ch_stub(::Analytics::OverviewStatsService, :sources_breakdown, stub_result) do
      get "#{API_PREFIX}/projects/#{@project.id}/analytics/overview/sources/breakdown",
          headers: @headers
    end

    assert_response :ok
    json = assert_analytics_schema(:sources_breakdown)
    assert_each_analytics_item(:source_item, json['sources'])
  end

  test 'version_distribution stubbed response validates distribution_item items' do
    stub_result = {
      entries: [
        { 'version' => '2.0.0', 'release_date' => '2026-01-01', 'platforms' => { 'ios' => 80 }, 'total' => 80 },
        { 'version' => '1.5.0', 'release_date' => nil, 'platforms' => { 'android' => 30 }, 'total' => 30 }
      ]
    }

    with_ch_stub(::Analytics::OverviewStatsService, :version_distribution, stub_result) do
      get "#{API_PREFIX}/projects/#{@project.id}/analytics/overview/versions/distribution",
          headers: @headers
    end

    assert_response :ok
    json = assert_analytics_schema(:version_distribution)
    assert_each_analytics_item(:distribution_item, json['entries'])
  end

  test 'events fields stubbed response validates field_item items' do
    stub_result = {
      fields: [
        { 'name' => 'event_type', 'type' => 'dimension' },
        { 'name' => 'engagement_time', 'type' => 'metric' }
      ]
    }

    with_ch_stub(::Analytics::EventsQueryService, :fields, stub_result) do
      get "#{API_PREFIX}/projects/#{@project.id}/analytics/events/fields",
          headers: @headers
    end

    assert_response :ok
    json = assert_analytics_schema(:events_fields)
    assert_each_analytics_item(:field_item, json['fields'])
  end

  test 'events volume stubbed response validates volume_bucket items' do
    stub_result = {
      buckets: [
        { 'bucket' => '2026-05-01', 'count' => 42 },
        { 'bucket' => '2026-05-02', 'count' => 55 }
      ]
    }

    with_ch_stub(::Analytics::EventsQueryService, :volume, stub_result) do
      get "#{API_PREFIX}/projects/#{@project.id}/analytics/events/volume",
          params: { start_date: '2026-05-01', end_date: '2026-05-08' },
          headers: @headers
    end

    assert_response :ok
    json = assert_analytics_schema(:events_volume)
    assert_each_analytics_item(:volume_bucket, json['buckets'])
  end

  # ── Negative path / injection tests (Fix #2) ────────────────────────
  # These exercise the full controller path with malicious or boundary
  # inputs. They verify no 500 errors escape — the controller should
  # either reject (400/422) or sanitize and return normally.

  test 'search param with SQL injection attempt does not cause 500' do
    stub_result = { data: [], next_cursor: nil, total_count: nil }

    with_ch_stub(::Analytics::EventsQueryService, :list, stub_result) do
      get "#{API_PREFIX}/projects/#{@project.id}/analytics/events",
          params: { search: "'; DROP TABLE events; --" },
          headers: @headers
    end

    # Should NOT be a 500 — either 200 (sanitized) or 400 (rejected)
    assert_includes [200, 400], response.status,
                    "SQL injection in search should not cause 500, got #{response.status}"
  end

  test 'search param with CH injection attempt does not cause 500' do
    stub_result = { data: [], next_cursor: nil }

    with_ch_stub(::Analytics::SessionsQueryService, :list, stub_result) do
      get "#{API_PREFIX}/projects/#{@project.id}/analytics/sessions",
          params: { filters: "[{\"field\":\"platform\",\"value\":\"Home' OR 1=1 --\"}]" },
          headers: @headers
    end

    assert_includes [200, 400], response.status,
                    "CH injection in filters should not cause 500, got #{response.status}"
  end

  test 'filters param with malformed JSON does not cause 500' do
    stub_result = { data: [], next_cursor: nil, total_count: nil }

    with_ch_stub(::Analytics::EventsQueryService, :list, stub_result) do
      get "#{API_PREFIX}/projects/#{@project.id}/analytics/events",
          params: { filters: '{not valid json[[[' },
          headers: @headers
    end

    assert_includes [200, 400], response.status,
                    "Malformed JSON filters should not cause 500, got #{response.status}"
  end

  test 'extremely large limit is clamped or rejected, not passed through' do
    captured = nil
    fake = lambda { |*args, **kw| 
      captured = [args, kw]
      { data: [], next_cursor: nil, total_count: nil }
    }

    with_ch_stub(::Analytics::EventsQueryService, :list, fake) do
      get "#{API_PREFIX}/projects/#{@project.id}/analytics/events",
          params: { limit: '999999' },
          headers: @headers
    end

    assert_response :ok
    # Limit should be clamped to max (200 per INPUT_SCHEMA), not 999999
    assert captured[1][:limit] <= 200,
           "Limit 999999 should be clamped, got #{captured[1][:limit]}"
  end

  test 'negative limit falls back to default' do
    captured = nil
    fake = lambda { |*args, **kw| 
      captured = [args, kw]
      { data: [], next_cursor: nil, total_count: nil }
    }

    with_ch_stub(::Analytics::EventsQueryService, :list, fake) do
      get "#{API_PREFIX}/projects/#{@project.id}/analytics/events",
          params: { limit: '-5' },
          headers: @headers
    end

    assert_response :ok
    assert captured[1][:limit] > 0, "Negative limit should fall back to positive default"
  end

  test 'unicode and emoji in search param does not cause 500' do
    stub_result = { data: [], next_cursor: nil, total_count: nil }

    with_ch_stub(::Analytics::EventsQueryService, :list, stub_result) do
      get "#{API_PREFIX}/projects/#{@project.id}/analytics/events",
          params: { search: "\u{1F4A9} SELECT * FROM events \u{0000}" },
          headers: @headers
    end

    assert_includes [200, 400], response.status,
                    "Unicode/emoji in search should not cause 500, got #{response.status}"
  end

  test 'cursor with injection attempt does not cause 500' do
    stub_result = { data: [], next_cursor: nil, total_count: nil }

    with_ch_stub(::Analytics::EventsQueryService, :list, stub_result) do
      get "#{API_PREFIX}/projects/#{@project.id}/analytics/events",
          params: { cursor: "'; DROP TABLE events; --" },
          headers: @headers
    end

    # Should be 400 (invalid cursor) not 500
    assert_response :bad_request
    assert_analytics_schema(:error_response)
  end

  test 'sessions source param with invalid value returns 400' do
    Clickhouse.stub(:read_enabled?, true) do
      get "#{API_PREFIX}/projects/#{@project.id}/analytics/sessions",
          params: { source: 'totally_bogus_source' },
          headers: @headers
    end

    assert_response :bad_request
    assert_analytics_schema(:error_response)
  end

  test 'field param with non-allowlisted value returns 400' do
    Clickhouse.stub(:read_enabled?, true) do
      get "#{API_PREFIX}/projects/#{@project.id}/analytics/events/field-values",
          params: { field: 'password_hash' },
          headers: @headers
    end

    assert_response :bad_request
  end

  test 'field param matching the declared user.<key> pattern is accepted' do
    pattern = INPUT_SCHEMAS[:events_field_values][:enum_patterns]['field']
    assert_match pattern, 'user.plan'

    with_ch_stub(::Analytics::EventsQueryService, :field_values, { values: [] }) do
      get "#{API_PREFIX}/projects/#{@project.id}/analytics/events/field-values",
          params: { field: 'user.plan' },
          headers: @headers
    end
    assert_response :ok
  end

  test 'field param failing the declared user.<key> pattern returns 400' do
    pattern = INPUT_SCHEMAS[:events_field_values][:enum_patterns]['field']
    assert_no_match pattern, 'user.bad`key'

    Clickhouse.stub(:read_enabled?, true) do
      get "#{API_PREFIX}/projects/#{@project.id}/analytics/events/field-values",
          params: { field: 'user.bad`key' },
          headers: @headers
    end
    assert_response :bad_request
  end

  test 'swapped start_date and end_date (start > end) does not cause 500' do
    stub_result = { data: [], next_cursor: nil, total_count: nil }

    with_ch_stub(::Analytics::EventsQueryService, :list, stub_result) do
      get "#{API_PREFIX}/projects/#{@project.id}/analytics/events",
          params: { start_date: '2026-05-08', end_date: '2026-05-01' },
          headers: @headers
    end

    # Should either succeed (empty) or return a validation error, not 500
    assert_includes [200, 400, 422], response.status,
                    "Swapped dates should not cause 500, got #{response.status}"
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

  # Find a migration file by name suffix, independent of version numbering scheme.
  def find_migration(name)
    matches = Dir[MIGRATIONS_PATH.join("*_#{name}.rb")]
    assert_equal 1, matches.size, "Expected exactly one migration matching '*_#{name}.rb', found #{matches.size}"
    matches.first
  end
end
