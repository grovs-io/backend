# frozen_string_literal: true

require 'test_helper'

# Behavioral guard test — does NOT require a live ClickHouse.
#
# We stub Clickhouse.with so the yielded connection raises a CH timeout
# DatabaseError (Code: 159). A read routed through `with_guard` maps that to
# Analytics::QueryTooHeavy and propagates it (QueryTooHeavy is a
# PROPAGATED_ERROR, so log_query_failure re-raises instead of swallowing).
#
# A raw `Clickhouse.with` read would instead be caught by the per-method
# `rescue StandardError => e; log_query_failure(...)` and degraded to an empty
# shape — no raise. So a propagated QueryTooHeavy proves the call path goes
# through with_guard.
class AnalyticsQueryGuardTest < ActiveSupport::TestCase
  # Real CH 26.x timeout message format (captured from a live server).
  TIMEOUT_ERROR = 'Code: 159. DB::Exception: Timeout exceeded: elapsed 1005.608 ms, maximum: 1000 ms. (TIMEOUT_EXCEEDED) (version 26.3.9.8 (official build))'

  setup { Rails.cache.clear }

  def with_timeout_connection
    raiser = Object.new
    raiser.define_singleton_method(:select_all) { |_sql| raise ClickHouse::Client::DatabaseError, TIMEOUT_ERROR }
    raiser.define_singleton_method(:select_value) { |_sql| raise ClickHouse::Client::DatabaseError, TIMEOUT_ERROR }
    Clickhouse.stub(:with, ->(&blk) { blk.call(raiser) }) do
      yield
    end
  end

  def assert_routes_through_guard(&blk)
    with_timeout_connection do
      assert_raises(Analytics::QueryTooHeavy, &blk)
    end
  end

  # Connection whose select_all SUCCEEDS on the first call (returning first_result
  # so the method proceeds past its first query) and raises a real CH timeout
  # DatabaseError on the SECOND call. Lets a test prove that a method running TWO
  # queries also routes its SECOND query through with_guard — without that guard
  # the timeout would be swallowed by the method's `rescue StandardError` and
  # degraded to an empty shape rather than surfacing as QueryTooHeavy.
  def with_second_query_timeout(first_result)
    calls = 0
    conn = Object.new
    conn.define_singleton_method(:select_all) do |_sql|
      calls += 1
      raise ClickHouse::Client::DatabaseError, TIMEOUT_ERROR if calls >= 2

      first_result
    end
    Clickhouse.stub(:with, ->(&blk) { blk.call(conn) }) do
      yield
    end
  end

  # --- EventsQueryService ---

  test 'EventsQueryService.list routes the data query through with_guard' do
    assert_routes_through_guard do
      Analytics::EventsQueryService.list(1, start_date: '2026-06-01', end_date: '2026-06-02')
    end
  end

  test 'EventsQueryService.find routes through with_guard' do
    assert_routes_through_guard do
      Analytics::EventsQueryService.find(1, event_id: 'e1')
    end
  end

  test 'EventsQueryService.volume routes through with_guard' do
    assert_routes_through_guard do
      Analytics::EventsQueryService.volume(1, start_date: '2026-06-01', end_date: '2026-06-02')
    end
  end

  test 'EventsQueryService.field_values routes an attribute field through with_guard' do
    assert_routes_through_guard do
      Analytics::EventsQueryService.field_values(1, field: 'event_type',
                                                    start_date: '2026-06-01', end_date: '2026-06-02')
    end
  end

  test 'EventsQueryService.fields routes the JSONAllPaths query through with_guard' do
    assert_routes_through_guard do
      Analytics::EventsQueryService.fields(1, start_date: '2026-06-01', end_date: '2026-06-02')
    end
  end

  # --- QueryHelpers (via EventsQueryService.field_values) ---

  test 'resolve_id_field routes through with_guard' do
    assert_routes_through_guard do
      Analytics::EventsQueryService.field_values(1, field: 'link_id')
    end
  end

  test 'ch_id_set routes through with_guard' do
    assert_routes_through_guard do
      Analytics::EventsQueryService.field_values(1, field: 'campaign_id', q: '1')
    end
  end

  test 'resolve_visitor_field routes through with_guard' do
    assert_routes_through_guard do
      Analytics::EventsQueryService.field_values(1, field: 'visitor_id')
    end
  end

  # --- OverviewStatsService ---

  test 'OverviewStatsService.versions routes through with_guard' do
    assert_routes_through_guard do
      Analytics::OverviewStatsService.versions(1, start_date: '2026-06-01', end_date: '2026-06-02')
    end
  end

  test 'OverviewStatsService.user_trends routes through with_guard' do
    assert_routes_through_guard do
      Analytics::OverviewStatsService.user_trends(1, start_date: '2026-06-01', end_date: '2026-06-02')
    end
  end

  test 'OverviewStatsService.sources_breakdown routes through with_guard' do
    assert_routes_through_guard do
      Analytics::OverviewStatsService.sources_breakdown(1, start_date: '2026-06-01', end_date: '2026-06-02')
    end
  end

  test 'OverviewStatsService.version_distribution routes through with_guard' do
    assert_routes_through_guard do
      Analytics::OverviewStatsService.version_distribution(1, start_date: '2026-06-01', end_date: '2026-06-02')
    end
  end

  # Second query = fetch_release_dates (overview_stats_service.rb:249). The first
  # query (count_rows) returns a row whose 'version' makes `versions` non-empty, so
  # fetch_release_dates actually runs its query; the cleared cache forces the
  # uncached branch instead of short-circuiting.
  test 'OverviewStatsService.version_distribution guards its SECOND query (fetch_release_dates)' do
    first = [{ 'version' => '1.0.0', 'platform' => 'ios', 'users' => 5 }]
    with_second_query_timeout(first) do
      assert_raises(Analytics::QueryTooHeavy) do
        Analytics::OverviewStatsService.version_distribution(1, start_date: '2026-06-01', end_date: '2026-06-02')
      end
    end
  end

  # --- RetentionService ---

  test 'RetentionService.summary routes through with_guard' do
    assert_routes_through_guard do
      Analytics::RetentionService.summary(1, start_date: '2026-06-01', end_date: '2026-06-02')
    end
  end

  # Second query = sparkline_sql (retention_service.rb:120). The first query
  # (rates_sql) succeeds and the method always proceeds to the sparkline query.
  test 'RetentionService.summary guards its SECOND query (sparkline_sql)' do
    first = [{ 'total_1' => 10, 'retained_1' => 5 }]
    with_second_query_timeout(first) do
      assert_raises(Analytics::QueryTooHeavy) do
        Analytics::RetentionService.summary(1, start_date: '2026-06-01', end_date: '2026-06-02')
      end
    end
  end

  # --- SessionsQueryService ---

  test 'SessionsQueryService.list routes through with_guard' do
    assert_routes_through_guard do
      Analytics::SessionsQueryService.list(1, start_date: '2026-06-01', end_date: '2026-06-02')
    end
  end

  test 'SessionsQueryService.find routes through with_guard' do
    assert_routes_through_guard do
      Analytics::SessionsQueryService.find(1, session_id: 's1', visitor_id: 1, event_date: '2026-06-01')
    end
  end

  # Second query = session_events (sessions_query_service.rb:90). The first query
  # (session) returns a non-nil session row so `return nil unless session` does not
  # short-circuit and the method proceeds to fetch the session's events.
  test 'SessionsQueryService.find guards its SECOND query (session_events)' do
    first = [{
      'session_id' => 's1', 'visitor_id' => 1, 'event_date' => '2026-06-01',
      'started_at' => '2026-06-01 00:00:00.000', 'ended_at' => '2026-06-01 00:05:00.000'
    }]
    with_second_query_timeout(first) do
      assert_raises(Analytics::QueryTooHeavy) do
        Analytics::SessionsQueryService.find(1, session_id: 's1', visitor_id: 1, event_date: '2026-06-01')
      end
    end
  end
end
