# frozen_string_literal: true

require 'test_helper'
require 'benchmark'

# Gated performance benchmark tests for ClickHouse analytics services.
#
# Generates a synthetic medium-sized dataset (10k events, ~1k sessions,
# 200 visitors) using a deterministic seed, then times each major analytics
# service call and asserts completion under generous thresholds.
#
# These tests exist for CI nightly runs, NOT PR checks. They catch gross
# performance regressions (e.g., missing WHERE clause causing full scans,
# N+1 CH queries, accidentally disabling pagination/limits).
#
# Double-gated:
#   1. skip_unless_clickhouse! -- requires a running CH instance
#   2. ENV['CH_PERF_TESTS']   -- opt-in for nightly CI
#
# Run: CH_PERF_TESTS=1 bundle exec rails test test/services/analytics/performance_test.rb
class Analytics::PerformanceTest < ActiveSupport::TestCase
  include ClickhouseTestHelper
  include GoldenDatasetHelper

  fixtures :projects, :instances

  # Generous thresholds -- these are ceilings, not targets.
  # If a test consistently finishes in 200ms, don't lower the threshold to 300ms.
  # These thresholds exist to catch order-of-magnitude regressions.
  READ_THRESHOLD_SECONDS = 2
  JOB_THRESHOLD_SECONDS  = 10

  # Synthetic dataset parameters (deterministic via seeded RNG).
  SEED           = 42
  NUM_VISITORS   = 200
  NUM_EVENTS     = 10_000
  DATE_SPAN_DAYS = 30
  NUM_PLATFORMS  = 3

  PLATFORMS     = %w[ios android web].freeze
  APP_VERSIONS  = %w[1.0 1.1 2.0 2.1 3.0].freeze
  COUNTRIES     = %w[US DE FR GB JP BR IN CA AU KR].freeze
  EVENT_TYPES   = %w[INSTALL OPEN VIEW TIME_SPENT APP_OPEN REINSTALL REACTIVATION USER_REFERRED].freeze
  SCREEN_NAMES  = %w[
    HomeScreen SettingsScreen ProfileScreen SearchScreen DetailScreen
    CheckoutScreen CartScreen LoginScreen SignupScreen DashboardScreen
    AnalyticsScreen ReportsScreen HelpScreen AboutScreen FeedScreen
    NotificationsScreen MessagesScreen MapScreen CameraScreen EditorScreen
  ].freeze

  setup do
    skip 'Performance tests gated behind CH_PERF_TESTS env var' unless ENV['CH_PERF_TESTS']
    skip_unless_clickhouse!
    @project = projects(:one)
    @rng = Random.new(SEED)
    generate_and_insert_synthetic_dataset
  end

  teardown do
    # No travel_back needed -- we don't use travel_to in perf tests.
  end

  # ---------------------------------------------------------------------------
  # 1. EventsQueryService.list completes under threshold
  # ---------------------------------------------------------------------------
  # The events list query scans the events table with project_id + date
  # filters and returns paginated results. On 10k events this should be fast
  # because the ORDER BY (project_id, toDate(created_at), ...) lets CH prune
  # aggressively.
  test 'events list completes under threshold' do
    elapsed = Benchmark.realtime do
      result = Analytics::EventsQueryService.list(
        @project.id,
        start_date:    @start_date,
        end_date:      @end_date,
        limit:         200,
        include_count: true
      )
      assert result[:data].any?, 'Expected non-empty events list result'
      assert result[:total_count].to_i > 0, 'Expected positive total_count'
    end

    assert elapsed < READ_THRESHOLD_SECONDS,
           "EventsQueryService.list took #{elapsed.round(3)}s, " \
           "expected under #{READ_THRESHOLD_SECONDS}s"
  end

  # ---------------------------------------------------------------------------
  # 5. SessionBuildJob.perform completes under threshold on 10k events
  # ---------------------------------------------------------------------------
  # The job scans recent events, deduplicates via LEFT ANTI JOIN against
  # session_events, sessionizes in Ruby, and inserts back into
  # session_events + session_summary. On 10k events / 200 visitors this
  # exercises both the CH queries and the Ruby sessionization loop.
  test 'session build job completes under threshold' do
    elapsed = Benchmark.realtime do
      # Stub enabled?/read_enabled? since they may not be true in test env
      Clickhouse.stub(:enabled?, true) do
        Clickhouse.stub(:read_enabled?, true) do
          SessionBuildJob.new.perform
        end
      end
    end

    # Verify the job actually did work
    session_count = Clickhouse.with do |conn|
      conn.select_value(
        "SELECT count() FROM session_events WHERE project_id = #{@project.id}"
      )
    end
    assert session_count.to_i > 0, 'SessionBuildJob should have created session_events rows'

    assert elapsed < JOB_THRESHOLD_SECONDS,
           "SessionBuildJob.perform took #{elapsed.round(3)}s on #{NUM_EVENTS} events, " \
           "expected under #{JOB_THRESHOLD_SECONDS}s"
  end

  # ---------------------------------------------------------------------------
  # 6. Large/absurd limits remain fast (services clamp internally)
  # ---------------------------------------------------------------------------
  # Verifies that passing absurd limit values doesn't cause the service to
  # return unbounded result sets or blow up query time. The services should
  # clamp to their MAX_LIMIT internally.
  test 'large limits remain bounded under threshold' do
    elapsed = Benchmark.realtime do
      # Events list with absurd limit -- should clamp to MAX_LIMIT (200)
      events_result = Analytics::EventsQueryService.list(
        @project.id,
        start_date:    @start_date,
        end_date:      @end_date,
        limit:         999_999,
        include_count: true
      )
      assert events_result[:data].size <= Analytics::EventsQueryService::MAX_LIMIT,
             "Events list should clamp to MAX_LIMIT, got #{events_result[:data].size} rows"

      # Field values with absurd limit -- should clamp to MAX_LIMIT (200)
      fv_result = Analytics::EventsQueryService.field_values(
        @project.id,
        field: 'platform',
        limit: 999_999
      )
      assert fv_result[:values].size <= Analytics::EventsQueryService::MAX_LIMIT,
             "Field values should clamp to MAX_LIMIT"

      # Volume with absurd date range (service handles internally)
      vol_result = Analytics::EventsQueryService.volume(
        @project.id,
        start_date: @start_date,
        end_date:   @end_date,
        bucket:     'day'
      )
      assert vol_result[:buckets].size <= DATE_SPAN_DAYS + 1,
             'Volume buckets should be bounded by date range'
    end

    assert elapsed < READ_THRESHOLD_SECONDS,
           "Large-limit queries took #{elapsed.round(3)}s combined, " \
           "expected under #{READ_THRESHOLD_SECONDS}s"
  end

  test 'fields discovery bounds high property cardinality and caches result' do
    previous_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new

    rows = 250.times.map do |i|
      {
        event_id: "field_cardinality_#{i}",
        project_id: @project.id,
        event_type: 'VIEW',
        properties: { "key_#{i}" => "value_#{i}" },
        created_at: Time.current.utc.strftime('%Y-%m-%d %H:%M:%S.%3N')
      }
    end
    rows.each_slice(100) { |batch| insert_ch_events(batch) }

    clickhouse_reads = 0
    original_with = Clickhouse.method(:with)
    Clickhouse.stub(:with, ->(&block) {
      clickhouse_reads += 1
      original_with.call(&block)
    }) do
      first = Analytics::EventsQueryService.fields(@project.id)
      second = Analytics::EventsQueryService.fields(@project.id)

      property_fields = first[:fields].select { |field| field[:type] == 'property' }
      assert_operator property_fields.size, :>, 0
      assert_operator property_fields.size, :<=, 100, 'dynamic discovery should stay bounded by the query limit'
      assert_equal first, second
      assert_equal 1, clickhouse_reads, 'second fields call should be served from cache'
    end
  ensure
    Rails.cache = previous_cache if defined?(previous_cache)
  end

  private

  # ===========================================================================
  # Synthetic Dataset Generator
  # ===========================================================================
  # Builds a deterministic medium-sized dataset using a seeded RNG. The goal
  # is realistic-ish data distribution, not statistical fidelity.
  #
  # Dataset shape:
  #   - 200 visitors, each assigned a random platform/version/country
  #   - 10,000 events spread across 30 days with realistic type distribution
  #   - ~50 events per visitor on average (varies 5-100 via geometric sampling)
  #   - Session IDs assigned via 30-min inactivity gap simulation
  #   - Screens chosen from a pool of 20, with some visitors having "favorite" screens
  #
  # Also inserts derived tables (user_profiles, visitor_daily) for retention
  # and overview queries.

  def generate_and_insert_synthetic_dataset
    @end_date   = Time.current.to_date.to_s
    @start_date = (Time.current.to_date - DATE_SPAN_DAYS).to_s
    base_time   = Time.current - DATE_SPAN_DAYS.days

    visitors = generate_visitors
    events   = generate_events(visitors, base_time)

    # Insert events in batches to avoid oversized payloads
    events.each_slice(2000) { |batch| insert_ch_events(batch) }

    # Insert derived tables for retention/overview queries
    insert_synthetic_user_profiles(visitors, events, base_time)
    insert_synthetic_visitor_daily(visitors, events, base_time)
  end

  # Generates visitor metadata: each visitor gets a stable platform, version,
  # country assignment.
  def generate_visitors
    NUM_VISITORS.times.map do |i|
      vid = 5000 + i
      {
        visitor_id: vid,
        platform:   PLATFORMS[@rng.rand(PLATFORMS.size)],
        version:    APP_VERSIONS[@rng.rand(APP_VERSIONS.size)],
        country:    COUNTRIES[@rng.rand(COUNTRIES.size)],
        # Each visitor has 2-3 "favorite" screens they visit most often
        fav_screens: SCREEN_NAMES.sample(3, random: @rng)
      }
    end
  end

  # Distributes NUM_EVENTS across visitors with varying activity levels.
  # Returns array of event hashes ready for insert_ch_events.
  def generate_events(visitors, base_time)
    pid = @project.id
    events = []
    event_counter = 0

    # Assign event counts per visitor: weighted so some are heavy users
    # Use a simple approach: split events roughly evenly with some variance
    budget = NUM_EVENTS
    visitor_event_counts = visitors.map do |_v|
      # Geometric-ish distribution: most visitors get ~30-70 events,
      # some get 5-10, a few get 100+
      count = [(@rng.rand(10..90)), budget].min
      budget -= count
      count
    end
    # Distribute remaining budget to first visitors
    visitors.each_with_index do |_v, i|
      break if budget <= 0
      add = [budget, 20].min
      visitor_event_counts[i] += add
      budget -= add
    end

    visitors.each_with_index do |visitor, vi|
      count = visitor_event_counts[vi]
      next if count.nil? || count <= 0

      session_counter = 0
      last_event_time = nil

      count.times do |ei|
        event_counter += 1

        # Spread events across the date range with some clustering
        day_offset = @rng.rand(DATE_SPAN_DAYS)
        minute_offset = @rng.rand(1440) # minutes within the day
        event_time = base_time + day_offset.days + minute_offset.minutes

        # Assign session: 30-min gap creates new session
        if last_event_time && (event_time - last_event_time) > 1800
          session_counter += 1
        end
        session_id = "perf_sess_#{visitor[:visitor_id]}_#{session_counter}"
        last_event_time = event_time

        # Event type distribution: most are OPEN/VIEW, some INSTALL/TIME_SPENT
        event_type = if ei == 0
                       'INSTALL'
                     else
                       weighted_event_type
                     end

        # Screen name: 70% from favorites, 30% from pool, empty for some types
        screen = if %w[INSTALL REINSTALL USER_REFERRED REACTIVATION].include?(event_type)
                   ''
                 elsif @rng.rand < 0.7
                   visitor[:fav_screens][@rng.rand(visitor[:fav_screens].size)]
                 else
                   SCREEN_NAMES[@rng.rand(SCREEN_NAMES.size)]
                 end

        events << {
          project_id:        pid,
          event_id:          "perf_evt_#{event_counter}",
          event_type:        event_type,
          event_name:        '',
          screen_name:       screen,
          visitor_id:        visitor[:visitor_id],
          device_id:         visitor[:visitor_id],
          link_id:           0,
          inviter_id:        0,
          campaign_id:       0,
          platform:          visitor[:platform],
          app_version:       visitor[:version],
          build:             '',
          vendor_id:         '',
          device_model:      '',
          os:                '',
          os_version:        '',
          timezone:          '',
          language:          '',
          country:           visitor[:country],
          city:              '',
          tracking_source:   '',
          tracking_medium:   '',
          tracking_campaign: '',
          ads_platform:      '',
          link_tags:         [],
          sdk_identifier:    '',
          session_id:        session_id,
          engagement_time:   %w[TIME_SPENT].include?(event_type) ? @rng.rand(1000..30_000) : 0,
          tags:              [],
          ip:                '',
          remote_ip:         '',
          path:              '',
          created_at:        event_time.utc.strftime(Analytics::QueryHelpers::CH_DATETIME_FMT)
        }
      end
    end

    events.sort_by { |e| [e[:visitor_id], e[:created_at]] }
  end

  # Weighted random event type: OPEN 40%, VIEW 25%, TIME_SPENT 15%,
  # APP_OPEN 10%, others 10% combined.
  def weighted_event_type
    r = @rng.rand(100)
    case r
    when 0..39  then 'OPEN'
    when 40..64 then 'VIEW'
    when 65..79 then 'TIME_SPENT'
    when 80..89 then 'APP_OPEN'
    when 90..93 then 'REINSTALL'
    when 94..96 then 'REACTIVATION'
    when 97..98 then 'USER_REFERRED'
    else             'INSTALL'
    end
  end

  # Insert user_profiles for retention queries. One row per visitor with
  # first_seen/last_seen derived from their events.
  def insert_synthetic_user_profiles(visitors, events, _base_time)
    pid = @project.id
    events_by_visitor = events.group_by { |e| e[:visitor_id] }

    profiles = visitors.filter_map do |visitor|
      vid = visitor[:visitor_id]
      visitor_events = events_by_visitor[vid]
      next unless visitor_events&.any?

      timestamps = visitor_events.map { |e| e[:created_at] }.sort
      {
        project_id:     pid,
        visitor_id:     vid,
        sdk_identifier: '',
        first_seen:     timestamps.first,
        last_seen:      timestamps.last,
        country:        visitor[:country],
        platform:       visitor[:platform],
        inviter_id:     0
      }
    end

    profiles.each_slice(1000) { |batch| insert_ch_user_profiles(batch) }
  end

  # Insert visitor_daily for retention and overview queries. One row per
  # visitor per active day.
  def insert_synthetic_visitor_daily(visitors, events, _base_time)
    pid = @project.id
    events_by_visitor = events.group_by { |e| e[:visitor_id] }

    rows = []
    visitors.each do |visitor|
      vid = visitor[:visitor_id]
      visitor_events = events_by_visitor[vid]
      next unless visitor_events&.any?

      # Group by date and count
      by_date = visitor_events.group_by { |e| e[:created_at][0, 10] } # YYYY-MM-DD prefix
      by_date.each do |date_str, day_events|
        rows << {
          project_id:            pid,
          visitor_id:            vid,
          event_date:            date_str,
          event_type:            'OPEN',
          platform:              visitor[:platform],
          cnt:                   day_events.size,
          total_engagement_time: day_events.sum { |e| e[:engagement_time] },
          inviter_id_state:      0
        }
      end
    end

    rows.each_slice(2000) { |batch| insert_ch_visitor_daily(batch) }
  end
end
