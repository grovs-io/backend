# frozen_string_literal: true

require 'test_helper'
require 'support/clickhouse_test_helper'

class SessionBuildJobTest < ActiveSupport::TestCase
  include ClickhouseTestHelper

  fixtures :instances, :projects

  setup do
    skip_unless_clickhouse!
    @project = projects(:one)
    @job = SessionBuildJob.new
    # These fixtures are all "currently active"; deferral has its own tests.
    @job.defer_open_sessions = false
  end

  # ── Guard clauses ────────────────────────────────────────────────────

  test 'perform: no-ops when CH is disabled' do
    Clickhouse.stub(:enabled?, false) do
      assert_nothing_raised { @job.perform }
    end
  end

  test 'perform: no-ops when CH reads are disabled' do
    Clickhouse.stub(:enabled?, true) do
      Clickhouse.stub(:read_enabled?, false) do
        assert_nothing_raised { @job.perform }
      end
    end
  end

  # ── format_timestamp ─────────────────────────────────────────────────

  test 'format_timestamp: Time object formatted as CH DateTime64 string' do
    time = Time.utc(2026, 5, 8, 14, 30, 15, 123_000)
    result = @job.send(:format_timestamp, time)
    assert_equal '2026-05-08 14:30:15.123', result
  end

  test 'format_timestamp: ActiveSupport::TimeWithZone converted to UTC' do
    time = Time.utc(2026, 5, 8, 14, 0, 0).in_time_zone('US/Eastern')
    result = @job.send(:format_timestamp, time)
    assert_equal '2026-05-08 14:00:00.000', result
  end

  test 'format_timestamp: String passed through unchanged' do
    assert_equal '2026-05-01 10:00:00.000', @job.send(:format_timestamp, '2026-05-01 10:00:00.000')
  end

  test 'format_timestamp: other objects use to_s' do
    assert_equal '12345', @job.send(:format_timestamp, 12_345)
  end

  # ── Sessionization logic (30-min gap) ────────────────────────────────

  test 'sessionize: events within 30-min gap get same synthetic session_id' do
    now = Time.current
    insert_ch_events([
      base_event(visitor_id: 1, created_at: fmt(now)),
      base_event(visitor_id: 1, created_at: fmt(now + 10.minutes)),
      base_event(visitor_id: 1, created_at: fmt(now + 20.minutes))
    ])

    @job.send(:build_sessions_for_project, @project.id)

    sessions = ch_query('session_events', @project.id)
    session_ids = sessions.map { |r| r['session_id'] }.uniq
    assert_equal 1, session_ids.size
    assert_equal 'synth_1_0', session_ids.first
  end

  test 'sessionize: events beyond 30-min gap get different synthetic session_id' do
    now = Time.current
    insert_ch_events([
      base_event(visitor_id: 1, created_at: fmt(now)),
      base_event(visitor_id: 1, created_at: fmt(now + 10.minutes)),
      base_event(visitor_id: 1, created_at: fmt(now + 45.minutes)) # >30 min gap
    ])

    @job.send(:build_sessions_for_project, @project.id)

    sessions = ch_query('session_events', @project.id)
    session_ids = sessions.map { |r| r['session_id'] }.uniq.sort
    assert_equal 2, session_ids.size
    assert_includes session_ids, 'synth_1_0'
    assert_includes session_ids, 'synth_1_1'
  end

  test 'sessionize: exactly 30-min gap (boundary) does NOT start new session' do
    now = Time.current
    insert_ch_events([
      base_event(visitor_id: 1, created_at: fmt(now)),
      base_event(visitor_id: 1, created_at: fmt(now + 30.minutes)) # exactly 1800s
    ])

    @job.send(:build_sessions_for_project, @project.id)

    sessions = ch_query('session_events', @project.id)
    session_ids = sessions.map { |r| r['session_id'] }.uniq
    assert_equal 1, session_ids.size, 'exactly 30 min should NOT start a new session'
  end

  test 'sessionize: 30-min + 1 second starts new session' do
    now = Time.current
    insert_ch_events([
      base_event(visitor_id: 1, created_at: fmt(now)),
      base_event(visitor_id: 1, created_at: fmt(now + 30.minutes + 1.second))
    ])

    @job.send(:build_sessions_for_project, @project.id)

    sessions = ch_query('session_events', @project.id)
    session_ids = sessions.map { |r| r['session_id'] }.uniq
    assert_equal 2, session_ids.size, '30m01s gap should start a new session'
  end

  test 'sessionize: preserves existing session_id from SDK' do
    now = Time.current
    insert_ch_events([
      base_event(visitor_id: 1, session_id: 'sdk_session_abc', created_at: fmt(now)),
      base_event(visitor_id: 1, session_id: 'sdk_session_abc', created_at: fmt(now + 5.minutes))
    ])

    @job.send(:build_sessions_for_project, @project.id)

    sessions = ch_query('session_events', @project.id)
    session_ids = sessions.map { |r| r['session_id'] }.uniq
    assert_equal ['sdk_session_abc'], session_ids
  end

  test 'sessionize: mixes existing and synthetic session_ids correctly' do
    now = Time.current
    insert_ch_events([
      base_event(visitor_id: 1, session_id: 'sdk_sess', created_at: fmt(now)),
      base_event(visitor_id: 1, session_id: '', created_at: fmt(now + 5.minutes)),
      base_event(visitor_id: 1, session_id: '', created_at: fmt(now + 50.minutes)) # >30 min from last
    ])

    @job.send(:build_sessions_for_project, @project.id)

    sessions = ch_query('session_events', @project.id)
    ids = sessions.sort_by { |r| r['created_at'] }.map { |r| r['session_id'] }
    assert_equal 'sdk_sess', ids[0]
    assert_match(/^synth_1_/, ids[1])
    assert_match(/^synth_1_/, ids[2])
    # The two synthetic events should have different session counters due to >30 min gap
    assert_not_equal ids[1], ids[2]
  end

  test 'sessionize: different visitors get independent session counters' do
    now = Time.current
    insert_ch_events([
      base_event(visitor_id: 1, created_at: fmt(now)),
      base_event(visitor_id: 2, created_at: fmt(now)),
      base_event(visitor_id: 1, created_at: fmt(now + 5.minutes)),
      base_event(visitor_id: 2, created_at: fmt(now + 5.minutes))
    ])

    @job.send(:build_sessions_for_project, @project.id)

    sessions = ch_query('session_events', @project.id)
    v1_ids = sessions.select { |r| r['visitor_id'] == 1 }.map { |r| r['session_id'] }.uniq
    v2_ids = sessions.select { |r| r['visitor_id'] == 2 }.map { |r| r['session_id'] }.uniq
    assert_equal 1, v1_ids.size
    assert_equal 1, v2_ids.size
    assert_equal 'synth_1_0', v1_ids.first
    assert_equal 'synth_2_0', v2_ids.first
  end

  # ── Deduplication ────────────────────────────────────────────────────

  test 'sessionize: skips events already in session_events (by event_id)' do
    now = Time.current
    event_id = "existing_#{SecureRandom.hex(4)}"

    # Pre-insert into session_events
    insert_ch_session_events([{
      project_id: @project.id, session_id: 'old_sess', visitor_id: 1,
      event_id: event_id, event_type: 'VIEW', event_date: now.to_date.to_s,
      created_at: fmt(now)
    }])

    # Same event_id in raw events
    insert_ch_events([
      base_event(visitor_id: 1, event_id: event_id, created_at: fmt(now))
    ])

    @job.send(:build_sessions_for_project, @project.id)

    # Should still have only 1 row in session_events (the pre-existing one)
    sessions = ch_query('session_events', @project.id)
    matching = sessions.select { |r| r['event_id'] == event_id }
    assert_equal 1, matching.size
  end

  test 'eligible_visitor_buckets: only visitors with unsessionized events are paged' do
    now = Time.current
    done_id = "done_#{SecureRandom.hex(4)}"
    insert_ch_events([
      base_event(visitor_id: 1, event_id: done_id, created_at: fmt(now - 10.minutes)),
      base_event(visitor_id: 2, created_at: fmt(now - 5.minutes))
    ])
    insert_ch_session_events([{
      project_id: @project.id, session_id: 'old_sess', visitor_id: 1,
      event_id: done_id, event_type: 'VIEW', event_date: now.to_date.to_s,
      created_at: fmt(now - 10.minutes)
    }])

    buckets = @job.send(:eligible_visitor_buckets, @project.id)

    assert_equal [[2, [2]]], buckets
  end

  test 'eligible_visitor_buckets: a late event re-admits an otherwise settled visitor' do
    now = Time.current
    done_id = "done_#{SecureRandom.hex(4)}"
    insert_ch_events([
      base_event(visitor_id: 1, event_id: done_id, created_at: fmt(now - 1.hour)),
      base_event(visitor_id: 1, created_at: fmt(now - 2.days))
    ])
    insert_ch_session_events([{
      project_id: @project.id, session_id: 'old_sess', visitor_id: 1,
      event_id: done_id, event_type: 'VIEW', event_date: now.to_date.to_s,
      created_at: fmt(now - 1.hour)
    }])

    assert_equal [[1, [1]]], @job.send(:eligible_visitor_buckets, @project.id)
  end

  # ── build_session_summaries ──────────────────────────────────────────

  test 'build_session_summaries: aggregates session_events into session_summary' do
    now = Time.current
    insert_ch_session_events([
      {
        project_id: @project.id, session_id: 'sess1', visitor_id: 1,
        event_id: 'e1', event_type: 'VIEW', event_name: 'page_view',
        screen_name: 'Home', platform: 'ios', app_version: '2.0',
        event_date: now.to_date.to_s, created_at: fmt(now)
      },
      {
        project_id: @project.id, session_id: 'sess1', visitor_id: 1,
        event_id: 'e2', event_type: 'VIEW', event_name: 'page_view',
        screen_name: 'Settings', platform: 'ios', app_version: '2.0',
        event_date: now.to_date.to_s, created_at: fmt(now + 2.minutes)
      }
    ])

    @job.send(:build_session_summaries, @project.id, Set['sess1'])

    summaries = ch_query('session_summary', @project.id)
    assert_equal 1, summaries.size

    summary = summaries.first
    assert_equal 'sess1', summary['session_id']
    assert_equal 1, summary['visitor_id']
    assert_equal 2, summary['event_count']
    assert_equal 2, summary['screen_count']
    assert_equal 'ios', summary['platform']
  end

  # ── ensure_time ─────────────────────────────────────────────────────

  test 'ensure_time: Time object returned as-is' do
    time = Time.utc(2026, 5, 8, 14, 30, 0)
    result = @job.send(:ensure_time, time)
    assert_instance_of Time, result
    assert_equal time, result
  end

  test 'ensure_time: ActiveSupport::TimeWithZone returned as-is' do
    time = Time.utc(2026, 5, 8, 14, 0, 0).in_time_zone('US/Eastern')
    result = @job.send(:ensure_time, time)
    assert_kind_of ActiveSupport::TimeWithZone, result
    assert_equal time, result
  end

  test 'ensure_time: String parsed into Time' do
    result = @job.send(:ensure_time, '2026-05-08 14:30:00')
    assert_instance_of Time, result
    assert_equal 2026, result.year
    assert_equal 5, result.month
    assert_equal 8, result.day
  end

  test 'ensure_time: Numeric (epoch) converted via Time.at' do
    epoch = Time.utc(2026, 5, 8, 14, 0, 0).to_i
    result = @job.send(:ensure_time, epoch)
    assert_instance_of Time, result
    assert_equal 2026, result.utc.year
  end

  test 'ensure_time: Float epoch works' do
    epoch = Time.utc(2026, 5, 8, 14, 0, 0).to_f
    result = @job.send(:ensure_time, epoch)
    assert_instance_of Time, result
  end

  test 'ensure_time: other object uses to_s then Time.parse' do
    date = Date.new(2026, 5, 8)
    result = @job.send(:ensure_time, date)
    assert_instance_of Time, result
    assert_equal 2026, result.year
  end

  # ── build_session_summaries only processes provided session_ids ────

  test 'build_session_summaries: only processes provided session_ids' do
    now = Time.current
    # Insert events for two different sessions
    insert_ch_session_events([
      { project_id: @project.id, session_id: 'sess_a', visitor_id: 1,
        event_id: 'e1', event_type: 'VIEW', event_date: now.to_date.to_s,
        screen_name: 'Home', created_at: fmt(now) },
      { project_id: @project.id, session_id: 'sess_b', visitor_id: 2,
        event_id: 'e2', event_type: 'VIEW', event_date: now.to_date.to_s,
        screen_name: 'Settings', created_at: fmt(now) }
    ])

    # Only build summary for sess_a
    @job.send(:build_session_summaries, @project.id, Set['sess_a'])
    summaries = ch_query('session_summary', @project.id)
    assert_equal 1, summaries.size
    assert_equal 'sess_a', summaries.first['session_id']
  end

  # ── Visitor batching ────────────────────────────────────────────────

  test 'sessionize: processes visitors across multiple batches correctly' do
    now = Time.current

    # Create events for 5 distinct visitors
    events = (1..5).flat_map do |vid|
      [
        base_event(visitor_id: vid, created_at: fmt(now)),
        base_event(visitor_id: vid, created_at: fmt(now + 5.minutes))
      ]
    end
    insert_ch_events(events)

    # Override BUCKET_BATCH_SIZE to 2 so 5 visitors require 3 batches (2+2+1)
    with_visitor_batch_size(2) do
      @job.send(:build_sessions_for_project, @project.id)
    end

    sessions = ch_query('session_events', @project.id)

    # All 10 events (2 per visitor × 5 visitors) should be sessionized
    assert_equal 10, sessions.size

    # Each visitor should have exactly 1 session (events within 30-min gap)
    (1..5).each do |vid|
      visitor_sessions = sessions.select { |r| r['visitor_id'] == vid }
      assert_equal 2, visitor_sessions.size, "visitor #{vid} should have 2 events"
      session_ids = visitor_sessions.map { |r| r['session_id'] }.uniq
      assert_equal 1, session_ids.size, "visitor #{vid} should have 1 session"
      assert_equal "synth_#{vid}_0", session_ids.first
    end
  end

  test 'sessionize: batching does not break session continuity within a visitor' do
    now = Time.current

    # Visitor 1 has events that span a 30-min gap
    # Visitor 2 has events within the gap
    # With batch_size=1, each visitor is a separate batch
    events = [
      base_event(visitor_id: 1, created_at: fmt(now)),
      base_event(visitor_id: 1, created_at: fmt(now + 45.minutes)), # new session
      base_event(visitor_id: 2, created_at: fmt(now)),
      base_event(visitor_id: 2, created_at: fmt(now + 10.minutes))  # same session
    ]
    insert_ch_events(events)

    with_visitor_batch_size(1) do
      @job.send(:build_sessions_for_project, @project.id)
    end

    sessions = ch_query('session_events', @project.id)
    assert_equal 4, sessions.size

    # Visitor 1: should have 2 sessions (30-min gap crossed)
    v1 = sessions.select { |r| r['visitor_id'] == 1 }.map { |r| r['session_id'] }.uniq.sort
    assert_equal 2, v1.size, 'visitor 1 should have 2 sessions'
    assert_includes v1, 'synth_1_0'
    assert_includes v1, 'synth_1_1'

    # Visitor 2: should have 1 session
    v2 = sessions.select { |r| r['visitor_id'] == 2 }.map { |r| r['session_id'] }.uniq
    assert_equal 1, v2.size, 'visitor 2 should have 1 session'
    assert_equal 'synth_2_0', v2.first
  end

  test 'sessionize: batch_size=1 processes every visitor independently' do
    now = Time.current
    events = (1..3).map { |vid| base_event(visitor_id: vid, created_at: fmt(now)) }
    insert_ch_events(events)

    with_visitor_batch_size(1) do
      @job.send(:build_sessions_for_project, @project.id)
    end

    sessions = ch_query('session_events', @project.id)
    assert_equal 3, sessions.size
    visitor_ids = sessions.map { |r| r['visitor_id'] }.sort
    assert_equal [1, 2, 3], visitor_ids
  end

  # ── Full pipeline (perform) ──────────────────────────────────────────

  test 'perform: no-ops gracefully when no events exist' do
    assert_nothing_raised { @job.perform }
    assert_equal 0, ch_query('session_events', @project.id).size
  end

  private

  # Drop and recreate all CH tables from current DDL. Tables may lack newer
  # columns if created by an older schema version (CREATE IF NOT EXISTS is a
  # no-op for existing tables). Also resets the ClickhouseTestHelper cached
  # flag so other test classes that call ensure_tables! will re-create tables
  # if this test class runs first.
  def recreate_clickhouse_tables!
    ClickhouseTestHelper.reset_schema!
    truncate_clickhouse_tables
  end

  # Temporarily override BUCKET_BATCH_SIZE for a block.
  def with_visitor_batch_size(size)
    old = SessionBuildJob::BUCKET_BATCH_SIZE
    SessionBuildJob.send(:remove_const, :BUCKET_BATCH_SIZE)
    SessionBuildJob.const_set(:BUCKET_BATCH_SIZE, size)
    yield
  ensure
    SessionBuildJob.send(:remove_const, :BUCKET_BATCH_SIZE)
    SessionBuildJob.const_set(:BUCKET_BATCH_SIZE, old)
  end

  def base_event(visitor_id:, created_at:, event_id: nil, session_id: '')
    {
      project_id: @project.id,
      event_id: event_id || SecureRandom.uuid,
      event_type: 'VIEW',
      event_name: 'page_view',
      screen_name: 'TestScreen',
      visitor_id: visitor_id,
      device_id: 1,
      platform: 'ios',
      app_version: '1.0',
      country: 'US',
      session_id: session_id,
      created_at: created_at
    }
  end

  def fmt(time)
    time.utc.strftime('%Y-%m-%d %H:%M:%S.%3N')
  end

  test "returns :skipped when another run holds the single-flight lock" do
    REDIS.with { |c| c.set("sidekiq:single_flight:session_build", "other", ex: 60) }

    assert_equal :skipped, SessionBuildJob.new.perform(lookback_days: 1)
  ensure
    REDIS.with { |c| c.del("sidekiq:single_flight:session_build") }
  end

  test "stops and reports when the lock deadline passes mid-run" do
    job = SessionBuildJob.new
    built = []
    advance = lambda { |pid|
      built << pid
      travel 2.hours
    }

    result = job.stub(:projects_with_recent_events, [1, 2, 3]) do
      job.stub(:build_sessions_for_project, advance) { job.perform(lookback_days: 1, lock_ttl: 60) }
    end

    assert_equal [1], built, "must stop rather than keep inserting past the lock TTL"
    assert_includes result, :deadline_exceeded
  ensure
    travel_back
    REDIS.with { |c| c.del("sidekiq:single_flight:session_build") }
  end
end
