# frozen_string_literal: true

require 'test_helper'

# Unit tests for SessionBuildJob's pure Ruby logic.
# These run WITHOUT ClickHouse — no skip_unless_clickhouse! guard.
class SessionBuildJobUnitTest < ActiveSupport::TestCase
  setup do
    @job = SessionBuildJob.new
  end

  LOCK_KEY = "sidekiq:single_flight:session_build"

  test 'perform skips processing while another run holds the single-flight lock' do
    REDIS.with { |c| c.set(LOCK_KEY, 'other-owner', nx: true, ex: 60) }
    Clickhouse.stub(:enabled?, true) do
      Clickhouse.stub(:read_enabled?, true) do
        @job.stub(:projects_with_recent_events, -> { raise 'must not run while locked' }) do
          assert_nothing_raised { @job.perform }
        end
      end
    end
  ensure
    REDIS.with { |c| c.del(LOCK_KEY) }
  end

  test 'perform runs and releases the lock when it is free' do
    ran = false
    Clickhouse.stub(:enabled?, true) do
      Clickhouse.stub(:read_enabled?, true) do
        record_run = lambda do
          ran = true
          []
        end
        @job.stub(:projects_with_recent_events, record_run) do
          @job.perform
        end
      end
    end
    assert ran, 'block should run when lock is free'
    assert_nil REDIS.with { |c| c.get(LOCK_KEY) }, 'lock must be released after run'
  end

  # ── format_timestamp ─────────────────────────────────────────────────

  test 'format_timestamp: Time object formatted as CH DateTime64 string' do
    time = Time.utc(2026, 5, 8, 14, 30, 15, 123_000)
    assert_equal '2026-05-08 14:30:15.123', @job.send(:format_timestamp, time)
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

  test 'format_timestamp: sub-millisecond precision truncated to 3 digits' do
    time = Time.utc(2026, 1, 1, 0, 0, 0, 999_999) # 999999 microseconds
    result = @job.send(:format_timestamp, time)
    assert_match(/\.\d{3}$/, result)
  end

  test 'format_timestamp: midnight UTC formatted correctly' do
    time = Time.utc(2026, 1, 1, 0, 0, 0)
    assert_equal '2026-01-01 00:00:00.000', @job.send(:format_timestamp, time)
  end

  # ── ensure_time ─────────────────────────────────────────────────────

  test 'ensure_time: Time object returned as-is' do
    time = Time.utc(2026, 5, 8, 14, 30, 0)
    result = @job.send(:ensure_time, time)
    assert_same time, result
  end

  test 'ensure_time: ActiveSupport::TimeWithZone returned as-is' do
    time = Time.utc(2026, 5, 8, 14, 0, 0).in_time_zone('US/Eastern')
    result = @job.send(:ensure_time, time)
    assert_kind_of ActiveSupport::TimeWithZone, result
    assert_equal time, result
  end

  test 'ensure_time: ISO string parsed into Time' do
    result = @job.send(:ensure_time, '2026-05-08 14:30:00')
    assert_instance_of Time, result
    assert_equal 2026, result.year
    assert_equal 5, result.month
    assert_equal 8, result.day
    assert_equal 14, result.hour
    assert_equal 30, result.min
  end

  test 'ensure_time: CH DateTime64 string with milliseconds parsed' do
    result = @job.send(:ensure_time, '2026-05-08 14:30:15.123')
    assert_instance_of Time, result
    assert_equal 15, result.sec
  end

  test 'ensure_time: integer epoch converted via Time.at' do
    epoch = Time.utc(2026, 5, 8, 14, 0, 0).to_i
    result = @job.send(:ensure_time, epoch)
    assert_instance_of Time, result
    assert_equal 2026, result.utc.year
    assert_equal 5, result.utc.month
  end

  test 'ensure_time: float epoch works' do
    epoch = Time.utc(2026, 5, 8, 14, 0, 0).to_f
    result = @job.send(:ensure_time, epoch)
    assert_instance_of Time, result
    assert_equal 2026, result.utc.year
  end

  test 'ensure_time: Date object parsed via to_s' do
    date = Date.new(2026, 5, 8)
    result = @job.send(:ensure_time, date)
    assert_instance_of Time, result
    assert_equal 2026, result.year
    assert_equal 5, result.month
    assert_equal 8, result.day
  end

  test 'ensure_time: invalid string raises ArgumentError' do
    assert_raises(ArgumentError) do
      @job.send(:ensure_time, 'not-a-time')
    end
  end

  # ── Sessionization algorithm (via mock events) ────────────────────

  # Test the sessionization logic by feeding mock event hashes through
  # the private method and capturing inserted rows via a mock CH connection.

  test 'sessionize algorithm: events within 30-min gap get same synthetic session_id' do
    now = Time.utc(2026, 5, 8, 12, 0, 0)
    events = [
      mock_event(visitor_id: 1, created_at: now, session_id: ''),
      mock_event(visitor_id: 1, created_at: now + 10.minutes, session_id: ''),
      mock_event(visitor_id: 1, created_at: now + 20.minutes, session_id: '')
    ]

    rows = run_sessionization(events)
    session_ids = rows.map { |r| r[:session_id] }.uniq
    assert_equal 1, session_ids.size
    assert_equal 'synth_1_0', session_ids.first
  end

  test 'sessionize algorithm: gap > 30 min starts new session' do
    now = Time.utc(2026, 5, 8, 12, 0, 0)
    events = [
      mock_event(visitor_id: 1, created_at: now, session_id: ''),
      mock_event(visitor_id: 1, created_at: now + 45.minutes, session_id: '')
    ]

    rows = run_sessionization(events)
    ids = rows.map { |r| r[:session_id] }
    assert_equal 'synth_1_0', ids[0]
    assert_equal 'synth_1_1', ids[1]
  end

  test 'sessionize algorithm: exactly 30 min (1800s) does NOT start new session' do
    now = Time.utc(2026, 5, 8, 12, 0, 0)
    events = [
      mock_event(visitor_id: 1, created_at: now, session_id: ''),
      mock_event(visitor_id: 1, created_at: now + 30.minutes, session_id: '')
    ]

    rows = run_sessionization(events)
    assert_equal 1, rows.map { |r| r[:session_id] }.uniq.size
  end

  test 'sessionize algorithm: 1801 seconds starts new session' do
    now = Time.utc(2026, 5, 8, 12, 0, 0)
    events = [
      mock_event(visitor_id: 1, created_at: now, session_id: ''),
      mock_event(visitor_id: 1, created_at: now + 1801.seconds, session_id: '')
    ]

    rows = run_sessionization(events)
    assert_equal 2, rows.map { |r| r[:session_id] }.uniq.size
  end

  test 'sessionize algorithm: preserves SDK-provided session_id' do
    now = Time.utc(2026, 5, 8, 12, 0, 0)
    events = [
      mock_event(visitor_id: 1, created_at: now, session_id: 'sdk_abc'),
      mock_event(visitor_id: 1, created_at: now + 5.minutes, session_id: 'sdk_abc')
    ]

    rows = run_sessionization(events)
    assert_equal ['sdk_abc'], rows.map { |r| r[:session_id] }.uniq
  end

  test 'sessionize algorithm: mixes SDK and synthetic sessions' do
    now = Time.utc(2026, 5, 8, 12, 0, 0)
    events = [
      mock_event(visitor_id: 1, created_at: now, session_id: 'sdk_1'),
      mock_event(visitor_id: 1, created_at: now + 5.minutes, session_id: ''),
      mock_event(visitor_id: 1, created_at: now + 50.minutes, session_id: '')
    ]

    rows = run_sessionization(events)
    ids = rows.map { |r| r[:session_id] }
    assert_equal 'sdk_1', ids[0]
    assert_match(/^synth_1_\d/, ids[1])
    assert_match(/^synth_1_\d/, ids[2])
    assert_not_equal ids[1], ids[2], '50-min gap should create different synthetic sessions'
  end

  test 'sessionize algorithm: different visitors get independent counters' do
    now = Time.utc(2026, 5, 8, 12, 0, 0)
    events = [
      mock_event(visitor_id: 1, created_at: now, session_id: ''),
      mock_event(visitor_id: 2, created_at: now, session_id: ''),
      mock_event(visitor_id: 1, created_at: now + 5.minutes, session_id: ''),
      mock_event(visitor_id: 2, created_at: now + 5.minutes, session_id: '')
    ]

    rows = run_sessionization(events)
    v1_ids = rows.select { |r| r[:visitor_id] == 1 }.map { |r| r[:session_id] }.uniq
    v2_ids = rows.select { |r| r[:visitor_id] == 2 }.map { |r| r[:session_id] }.uniq
    assert_equal ['synth_1_0'], v1_ids
    assert_equal ['synth_2_0'], v2_ids
  end

  test 'sessionize algorithm: multiple session gaps accumulate counter' do
    now = Time.utc(2026, 5, 8, 12, 0, 0)
    events = [
      mock_event(visitor_id: 1, created_at: now, session_id: ''),
      mock_event(visitor_id: 1, created_at: now + 45.minutes, session_id: ''),
      mock_event(visitor_id: 1, created_at: now + 90.minutes, session_id: '')
    ]

    rows = run_sessionization(events)
    ids = rows.map { |r| r[:session_id] }
    assert_equal 'synth_1_0', ids[0]
    assert_equal 'synth_1_1', ids[1]
    assert_equal 'synth_1_2', ids[2]
  end

  # ── Row output shape ──────────────────────────────────────────────

  test 'sessionize algorithm: output row has all expected keys' do
    now = Time.utc(2026, 5, 8, 12, 0, 0)
    events = [mock_event(visitor_id: 1, created_at: now, session_id: '')]

    rows = run_sessionization(events)
    row = rows.first
    expected_keys = %i[
      project_id session_id visitor_id device_id event_id event_date
      event_type event_name screen_name platform app_version country
      device_model link_id campaign_id tracking_source engagement_time
      properties created_at sdk_generated link_visitor_id
    ]
    expected_keys.each do |key|
      assert row.key?(key), "Row missing key: #{key}"
    end
  end

  test 'sessionize algorithm: event_date derived from created_at' do
    now = Time.utc(2026, 5, 8, 14, 30, 0)
    events = [mock_event(visitor_id: 1, created_at: now, session_id: '')]

    rows = run_sessionization(events)
    assert_equal '2026-05-08', rows.first[:event_date]
  end

  test 'sessionize algorithm: properties defaults to empty hash for non-Hash input' do
    now = Time.utc(2026, 5, 8, 12, 0, 0)
    events = [mock_event(visitor_id: 1, created_at: now, session_id: '', properties: 'not_a_hash')]

    rows = run_sessionization(events)
    assert_equal({}, rows.first[:properties])
  end

  test 'sessionize algorithm: properties preserved when already a Hash' do
    now = Time.utc(2026, 5, 8, 12, 0, 0)
    events = [mock_event(visitor_id: 1, created_at: now, session_id: '', properties: { 'key' => 'val' })]

    rows = run_sessionization(events)
    assert_equal({ 'key' => 'val' }, rows.first[:properties])
  end

  # ── Source attribution copy-through ──────────────────────────────

  test 'sessionize algorithm: copies sdk_generated and link_visitor_id to output row' do
    now = Time.utc(2026, 5, 8, 12, 0, 0)
    event = mock_event(visitor_id: 1, created_at: now, session_id: '')
    event['sdk_generated'] = 1
    event['link_visitor_id'] = 42

    rows = run_sessionization([event])
    assert_equal 1, rows.first[:sdk_generated]
    assert_equal 42, rows.first[:link_visitor_id]
  end

  test 'sessionize algorithm: defaults sdk_generated and link_visitor_id to 0' do
    now = Time.utc(2026, 5, 8, 12, 0, 0)
    events = [mock_event(visitor_id: 1, created_at: now, session_id: '')]

    rows = run_sessionization(events)
    assert_equal 0, rows.first[:sdk_generated]
    assert_equal 0, rows.first[:link_visitor_id]
  end

  # ── Guard clauses ────────────────────────────────────────────────

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

  test 'sessionize_visitor_batch: rejects non-integer visitor ids before building SQL' do
    assert_raises(ArgumentError) do
      @job.send(:sessionize_visitor_batch, 1, [[1, ['1) OR 1=1 --']]])
    end
  end

  # ── Constants ──────────────────────────────────────────────────────

  test 'INACTIVITY_GAP_SECONDS is 1800 (30 minutes)' do
    assert_equal 1800, SessionBuildJob::INACTIVITY_GAP_SECONDS
  end

  test 'DEFAULT_LOOKBACK_DAYS is 3' do
    assert_equal 3, SessionBuildJob::DEFAULT_LOOKBACK_DAYS
  end

  test 'BATCH_SIZE is 10_000' do
    assert_equal 10_000, SessionBuildJob::BATCH_SIZE
  end

  test 'BUCKET_BATCH_SIZE is 500' do
    assert_equal 500, SessionBuildJob::BUCKET_BATCH_SIZE
  end

  private

  # Delegates to the production sessionize_events method so the test always
  # exercises the real algorithm. Returns only the rows (discards affected_sessions).
  def run_sessionization(events)
    rows, _affected, state = @job.send(:sessionize_events, events, 1)
    tail, = @job.send(:flush_pending_rows, state[:pending])
    rows + tail
  end

  def mock_event(visitor_id:, created_at:, session_id: '', properties: {})
    {
      'visitor_id' => visitor_id,
      'device_id' => 1,
      'event_id' => SecureRandom.uuid,
      'event_type' => 'VIEW',
      'event_name' => 'page_view',
      'screen_name' => 'TestScreen',
      'platform' => 'ios',
      'app_version' => '1.0',
      'country' => 'US',
      'device_model' => 'iPhone14',
      'link_id' => 0,
      'campaign_id' => 0,
      'tracking_source' => 'organic',
      'engagement_time' => 1000,
      'properties' => properties,
      'session_id' => session_id,
      'sdk_generated' => 0,
      'link_visitor_id' => 0,
      'created_at' => created_at
    }
  end

  test 'every session_events read carries an event_date floor so the sort key can prune' do
    captured = []
    fake_conn = Object.new
    fake_conn.define_singleton_method(:select_all) do |sql| 
      captured << sql
      []
    end

    Clickhouse.stub(:with, ->(&blk) { blk.call(fake_conn) }) do
      @job.send(:fetch_events_page, 1, '1, 2', '1, 2', 'e.visitor_id', nil)
      @job.send(:fetch_prior_session_state, 1, '1, 2', {})
    end
    captured << @job.send(:visitor_bucket_sql, 1)
    captured << @job.send(:session_agg_sql, 1, "'s1'", {})

    assert_equal 4, captured.size
    captured.each do |sql|
      assert_match(/event_date >= toDate\(now\(\) - INTERVAL \d+ (DAY|SECOND)\) - 1/, sql,
                   "session_events read without an event_date floor:\n#{sql}")
    end
  end
end
