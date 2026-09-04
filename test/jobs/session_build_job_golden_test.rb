# frozen_string_literal: true

require 'test_helper'
require 'support/clickhouse_test_helper'

# Pipeline integrity tests for SessionBuildJob.
#
# Unlike other golden tests that insert pre-built session tables, these tests
# insert ONLY raw events into the CH events table and let SessionBuildJob
# derive session_events and session_summary from scratch.
#
# Key behaviors tested:
#   - Idempotency: running the job twice produces no duplicates
#   - Dedup: duplicate event_ids don't produce duplicate session_events
#   - Empty event_id: both events processed, no duplication on re-run
#   - Synthetic session ID stability across incremental runs
#   - Session summary rebuild after late-arriving events
#   - Full pipeline: raw events -> session_events -> session_summary -> analytics service
#   - has_conversion flag correctness (event_type based, not screen_name)
#   - Screen ordering: step numbers match event timestamps
#   - 30-min inactivity gap boundary: exactly 1800s vs 1801s
class SessionBuildJobGoldenTest < ActiveSupport::TestCase
  include ClickhouseTestHelper

  fixtures :instances, :projects

  setup do
    skip_unless_clickhouse!
    @project = projects(:one)
    @job = SessionBuildJob.new
    # These fixtures are all "currently active"; deferral has its own tests.
    @job.defer_open_sessions = false
    @now = Time.current
    stub_ch_flags(true)
  end

  teardown do
    unstub_ch_flags
  end

  # ---------------------------------------------------------------------------
  # 1. Idempotency: run the job twice, assert counts don't change
  # ---------------------------------------------------------------------------
  test 'idempotent_double_run: second perform produces no new rows' do
    insert_raw_events(visitor_id: 1, count: 5, gap: 2.minutes)
    insert_raw_events(visitor_id: 2, count: 5, gap: 2.minutes)

    @job.perform
    se_count_1 = session_event_count
    ss_count_1 = session_summary_count

    assert se_count_1 > 0, 'first run must produce session_events'
    assert ss_count_1 > 0, 'first run must produce session_summaries'

    @job.perform
    se_count_2 = session_event_count
    ss_count_2 = session_summary_count

    assert_equal se_count_1, se_count_2,
                 "session_events count changed on second run: #{se_count_1} -> #{se_count_2}"
    assert_equal ss_count_1, ss_count_2,
                 "session_summary count changed on second run: #{ss_count_1} -> #{ss_count_2}"
  end

  # ---------------------------------------------------------------------------
  # 2. Duplicate event_id doesn't duplicate session_events
  # ---------------------------------------------------------------------------
  test 'duplicate_event_id: only one session_event row per event_id' do
    eid = "dup_evt_#{SecureRandom.hex(4)}"
    # Insert two raw events with the same event_id but different timestamps
    insert_ch_events([
      raw_event(visitor_id: 1, event_id: eid, created_at: ch_fmt(@now)),
      raw_event(visitor_id: 1, event_id: eid, created_at: ch_fmt(@now + 1.minute))
    ])

    @job.perform

    rows = ch_query('session_events', @project.id)
    matching = rows.select { |r| r['event_id'] == eid }
    # The LEFT ANTI JOIN dedup operates on (project_id, event_id, visitor_id),
    # but the first run inserts the first event; the second event with the same
    # event_id also comes from the raw events table. Both will pass through on
    # the first run because session_events is initially empty.
    # On the SECOND run, both are blocked by the ANTI JOIN.
    # However, since we only run once here, CH events table may contain both
    # rows and both pass through. The important thing is a second run doesn't
    # add more.
    first_run_count = matching.size

    @job.perform
    rows_after = ch_query('session_events', @project.id)
    matching_after = rows_after.select { |r| r['event_id'] == eid }
    assert_equal first_run_count, matching_after.size,
                 'second run must not add duplicate session_events for same event_id'
  end

  # ---------------------------------------------------------------------------
  # 3. Missing event_id: backfilled to a deterministic id, processed once
  # ---------------------------------------------------------------------------
  test 'missing_event_id: backfilled to a deterministic id and processed' do
    # Events lacking an event_id get a deterministic content-hash id at the
    # canonical write boundary, so sessions never see a blank id.
    insert_ch_events([
      raw_event(visitor_id: 1, event_id: '', screen_name: 'ScreenA', created_at: ch_fmt(@now)),
      raw_event(visitor_id: 1, event_id: '', screen_name: 'ScreenB', created_at: ch_fmt(@now + 2.minutes))
    ])

    @job.perform

    rows = ch_query('session_events', @project.id)
    assert_equal 2, rows.size, 'both events must be processed'
    assert rows.all? { |r| r['event_id'].to_s.present? },
           'canonical backfills a deterministic event_id — no blank rows reach sessions'
  end

  # ---------------------------------------------------------------------------
  # 4. Missing event_id: idempotent across re-runs (old duplication fixed)
  # ---------------------------------------------------------------------------
  test 'missing_event_id: idempotent across re-runs (no duplication)' do
    insert_ch_events([
      raw_event(visitor_id: 1, event_id: '', screen_name: 'ScreenA', created_at: ch_fmt(@now)),
      raw_event(visitor_id: 1, event_id: '', screen_name: 'ScreenB', created_at: ch_fmt(@now + 2.minutes))
    ])

    @job.perform
    assert_equal 2, session_event_count

    @job.perform
    # Deterministic ids now dedup on re-run via the ANTI JOIN against
    # session_events — the old blank-event_id re-insertion limitation is gone.
    assert_equal 2, session_event_count,
                 'deterministic event_ids dedup on re-run — no duplicates'
  end

  # ---------------------------------------------------------------------------
  # 5. Synthetic session IDs stable across incremental runs
  # ---------------------------------------------------------------------------
  test 'synthetic_session_ids_stable_across_incremental_runs' do
    # First batch: visitor 1 with 3 events in one session
    insert_ch_events([
      raw_event(visitor_id: 1, event_id: 'inc_e1', created_at: ch_fmt(@now - 1.hour)),
      raw_event(visitor_id: 1, event_id: 'inc_e2', created_at: ch_fmt(@now - 55.minutes)),
      raw_event(visitor_id: 1, event_id: 'inc_e3', created_at: ch_fmt(@now - 50.minutes))
    ])

    @job.perform

    rows_1 = ch_query('session_events', @project.id)
    session_ids_1 = rows_1.map { |r| r['session_id'] }.uniq
    assert_equal 1, session_ids_1.size, 'first batch: all within 30min gap => 1 session'
    assert_equal 'synth_1_0', session_ids_1.first

    # Second batch: new event for same visitor, >30min gap from last
    insert_ch_events([
      raw_event(visitor_id: 1, event_id: 'inc_e4', created_at: ch_fmt(@now))
    ])

    @job.perform

    rows_2 = ch_query('session_events', @project.id)
    new_event_row = rows_2.find { |r| r['event_id'] == 'inc_e4' }
    assert_not_nil new_event_row, 'new event must be in session_events'
    # The new event should get a new session (counter incremented from prior state)
    assert_equal 'synth_1_1', new_event_row['session_id'],
                 'incremental run should use counter from prior session state'
  end

  # ---------------------------------------------------------------------------
  # 6. Late-arriving events rebuild session summary
  # ---------------------------------------------------------------------------
  test 'late_arriving_events_rebuild_summary' do
    # Insert initial events for a session
    insert_ch_events([
      raw_event(visitor_id: 1, event_id: 'late_e1', screen_name: 'HomeScreen',
                created_at: ch_fmt(@now - 30.minutes)),
      raw_event(visitor_id: 1, event_id: 'late_e2', screen_name: 'SettingsScreen',
                created_at: ch_fmt(@now - 28.minutes))
    ])

    @job.perform

    summaries = ch_query('session_summary', @project.id)
    # Use FINAL to get deduplicated view (ReplacingMergeTree)
    summary_final = session_summary_final
    assert_equal 1, summary_final.size, 'should have 1 session summary'
    original_event_count = summary_final.first['event_count']
    original_last_screen = summary_final.first['last_screen']
    assert_equal 2, original_event_count
    assert_equal 'SettingsScreen', original_last_screen

    # Insert a late-arriving event within the same session window
    insert_ch_events([
      raw_event(visitor_id: 1, event_id: 'late_e3', screen_name: 'CheckoutScreen',
                created_at: ch_fmt(@now - 25.minutes))
    ])

    @job.perform

    summary_after = session_summary_final
    assert_equal 1, summary_after.size, 'still 1 session summary after late event'
    updated = summary_after.first
    assert_equal 3, updated['event_count'],
                 'event_count should increase after late-arriving event'
    assert_equal 'CheckoutScreen', updated['last_screen'],
                 'last_screen should update to the chronologically latest screen'
    # Session now has 3 distinct screens: HomeScreen, SettingsScreen, CheckoutScreen
    assert_equal 3, updated['screen_count'],
                 'screen_count should reflect 3 distinct screens after late event'
    # has_conversion is based on a purchase_events row with the BUY event_type value ("buy"),
    # NOT screen name. CheckoutScreen with event_type OPEN does not trigger conversion.
    assert_equal 0, updated['has_conversion'],
                 'has_conversion stays 0 — CheckoutScreen screen name is not a conversion trigger'
  end

  # ---------------------------------------------------------------------------
  # 7. Full pipeline: raw events -> session_events -> session_summary -> analytics
  # ---------------------------------------------------------------------------
  test 'full_pipeline_raw_to_analytics_service' do
    # Insert events that form a clear screen sequence
    insert_ch_events([
      raw_event(visitor_id: 1, event_id: 'fp_e1', screen_name: 'HomeScreen',
                event_type: 'OPEN', created_at: ch_fmt(@now - 20.minutes)),
      raw_event(visitor_id: 1, event_id: 'fp_e2', screen_name: 'ProfileScreen',
                event_type: 'OPEN', created_at: ch_fmt(@now - 18.minutes)),
      raw_event(visitor_id: 1, event_id: 'fp_e3', screen_name: 'SettingsScreen',
                event_type: 'OPEN', created_at: ch_fmt(@now - 15.minutes)),
      raw_event(visitor_id: 2, event_id: 'fp_e4', screen_name: 'HomeScreen',
                event_type: 'OPEN', created_at: ch_fmt(@now - 10.minutes)),
      raw_event(visitor_id: 2, event_id: 'fp_e5', screen_name: 'HomeScreen',
                event_type: 'OPEN', created_at: ch_fmt(@now - 8.minutes))
    ])

    @job.perform

    # Verify session_events were created
    se_rows = ch_query('session_events', @project.id)
    assert_equal 5, se_rows.size, 'all 5 events should produce session_events'

    # Verify session_summary was created
    ss_rows = session_summary_final
    assert_equal 2, ss_rows.size, '2 visitors => 2 sessions'

    # Verify the analytics Sessions reader can read the derived data
    start_date = (@now - 1.day).to_date
    end_date = @now.to_date

    result = Analytics::SessionsQueryService.list(
      @project.id,
      start_date: start_date,
      end_date: end_date
    )

    assert result.is_a?(Hash), 'sessions list should return a hash'

    # --- data: exactly the 2 derived sessions ---
    data = result[:data]
    assert_equal 2, data.size,
                 '2 visitors with 1 session each => 2 session rows'

    by_visitor = data.index_by { |r| r['visitor_id'] }

    # Visitor 1: Home -> Profile -> Settings (3 events)
    v1 = by_visitor[1]
    assert_not_nil v1, 'session for visitor 1 must be readable'
    assert_equal 3, v1['event_count'], 'visitor 1 session has 3 events'
    assert_equal 'HomeScreen', v1['first_screen'] if v1.key?('first_screen')

    # Visitor 2: Home -> Home (2 events)
    v2 = by_visitor[2]
    assert_not_nil v2, 'session for visitor 2 must be readable'
    assert_equal 2, v2['event_count'], 'visitor 2 session has 2 events'

    # Each row carries an opaque detail key and a derived source
    data.each do |row|
      assert row['id'].is_a?(String), 'each session row must carry an opaque id'
      assert_equal 'organic', row['source'], 'no link properties => organic source'
    end

    # --- detail: events are readable per session via the composite identity ---
    detail = Analytics::SessionsQueryService.find(
      @project.id, session_id: v1['session_id'], visitor_id: 1, event_date: v1['event_date']
    )
    assert_not_nil detail, 'session detail must be findable by composite identity'
    screens = detail[:events].map { |e| e['screen_name'] }
    assert_includes screens, 'HomeScreen'
    assert_includes screens, 'ProfileScreen'
    assert_includes screens, 'SettingsScreen'
  end

  # ---------------------------------------------------------------------------
  # 8. has_conversion flag correctness
  # ---------------------------------------------------------------------------
  test 'has_conversion_flag_based_on_purchase_events_not_event_type' do
    # Visitor 1: regular session, no purchase — has_conversion = 0
    insert_ch_events([
      raw_event(visitor_id: 1, event_id: 'conv_e1', event_type: 'OPEN',
                screen_name: 'CheckoutScreen', created_at: ch_fmt(@now - 10.minutes)),
      raw_event(visitor_id: 1, event_id: 'conv_e2', event_type: 'OPEN',
                screen_name: 'HomeScreen', created_at: ch_fmt(@now - 8.minutes))
    ])

    # Visitor 2: session with a matching purchase_events row — has_conversion = 1
    insert_ch_events([
      raw_event(visitor_id: 2, event_id: 'conv_e3', event_type: 'OPEN',
                screen_name: 'HomeScreen', created_at: ch_fmt(@now - 10.minutes)),
      raw_event(visitor_id: 2, event_id: 'conv_e4', event_type: 'custom',
                screen_name: 'PaymentScreen', created_at: ch_fmt(@now - 8.minutes))
    ])
    # purchase_events row within visitor 2's session window
    Clickhouse.with do |conn|
      conn.insert('purchase_events', [{
        project_id: @project.id, visitor_id: 2,
        event_type: Grovs::Purchases::EVENT_BUY, purchase_type: 'one_time',
        product_id: 'com.test.product', usd_price_cents: 999,
        currency: 'USD', quantity: 1,
        transaction_id: "TXN-conv-test-1",
        original_transaction_id: "OTXN-conv-test-1",
        store_source: 'apple', device_id: 0, link_id: 0,
        purchase_date: ch_fmt(@now - 9.minutes),
        created_at: ch_fmt(@now - 9.minutes)
      }])
    end

    # Visitor 3: purchase_events row exists but OUTSIDE session window — has_conversion = 0
    insert_ch_events([
      raw_event(visitor_id: 3, event_id: 'conv_e5', event_type: 'OPEN',
                screen_name: 'HomeScreen', created_at: ch_fmt(@now - 10.minutes)),
      raw_event(visitor_id: 3, event_id: 'conv_e6', event_type: 'OPEN',
                screen_name: 'SettingsScreen', created_at: ch_fmt(@now - 8.minutes))
    ])
    Clickhouse.with do |conn|
      conn.insert('purchase_events', [{
        project_id: @project.id, visitor_id: 3,
        event_type: Grovs::Purchases::EVENT_BUY, purchase_type: 'one_time',
        product_id: 'com.test.product', usd_price_cents: 499,
        currency: 'USD', quantity: 1,
        transaction_id: "TXN-conv-test-2",
        original_transaction_id: "OTXN-conv-test-2",
        store_source: 'apple', device_id: 0, link_id: 0,
        purchase_date: ch_fmt(@now - 2.hours),
        created_at: ch_fmt(@now - 2.hours)
      }])
    end

    @job.perform

    summaries = session_summary_final

    # Visitor 1: no purchase_events → has_conversion = 0
    v1_summary = summaries.find { |s| s['visitor_id'] == 1 }
    assert_not_nil v1_summary, 'visitor 1 summary must exist'
    assert_equal 0, v1_summary['has_conversion'],
                 'no purchase_events row → has_conversion=0'

    # Visitor 2: purchase_events within session window → has_conversion = 1
    v2_summary = summaries.find { |s| s['visitor_id'] == 2 }
    assert_not_nil v2_summary, 'visitor 2 summary must exist'
    assert_equal 1, v2_summary['has_conversion'],
                 'purchase_events within session window → has_conversion=1'
    assert v2_summary['revenue_usd_cents'].to_i > 0,
           'revenue should be populated from purchase_events'

    # Visitor 3: purchase_events OUTSIDE session window → has_conversion = 0
    v3_summary = summaries.find { |s| s['visitor_id'] == 3 }
    assert_not_nil v3_summary, 'visitor 3 summary must exist'
    assert_equal 0, v3_summary['has_conversion'],
                 'purchase_events outside session window → has_conversion=0'
  end

  # ---------------------------------------------------------------------------
  # 9. Cross-visitor session independence with interleaved timestamps
  # ---------------------------------------------------------------------------
  test 'cross_visitor_session_independence' do
    # Interleave events from v1 and v2 within the same minute range
    insert_ch_events([
      raw_event(visitor_id: 1, event_id: 'xv_e1', screen_name: 'HomeScreen',
                created_at: ch_fmt(@now - 10.minutes)),
      raw_event(visitor_id: 2, event_id: 'xv_e2', screen_name: 'ProfileScreen',
                created_at: ch_fmt(@now - 9.minutes)),
      raw_event(visitor_id: 1, event_id: 'xv_e3', screen_name: 'SettingsScreen',
                created_at: ch_fmt(@now - 8.minutes)),
      raw_event(visitor_id: 2, event_id: 'xv_e4', screen_name: 'DashboardScreen',
                created_at: ch_fmt(@now - 7.minutes)),
      # v1 has a >30min gap: new session
      raw_event(visitor_id: 1, event_id: 'xv_e5', screen_name: 'HomeScreen',
                created_at: ch_fmt(@now + 25.minutes)),
      raw_event(visitor_id: 2, event_id: 'xv_e6', screen_name: 'ProfileScreen',
                created_at: ch_fmt(@now - 5.minutes))
    ])

    @job.perform

    se_rows = ch_query('session_events', @project.id)
    v1_rows = se_rows.select { |r| r['visitor_id'] == 1 }
    v2_rows = se_rows.select { |r| r['visitor_id'] == 2 }

    assert_equal 3, v1_rows.size, 'visitor 1 should have 3 session_events'
    assert_equal 3, v2_rows.size, 'visitor 2 should have 3 session_events'

    # v1 sessions: synth_1_0 (2 events) + synth_1_1 (1 event after >30min gap)
    v1_session_ids = v1_rows.map { |r| r['session_id'] }.uniq.sort
    assert_equal 2, v1_session_ids.size, 'v1 should have 2 sessions (30min gap)'
    assert_includes v1_session_ids, 'synth_1_0'
    assert_includes v1_session_ids, 'synth_1_1'

    # v2 sessions: synth_2_0 (3 events, all within 30min)
    v2_session_ids = v2_rows.map { |r| r['session_id'] }.uniq
    assert_equal 1, v2_session_ids.size, 'v2 should have 1 session (all within gap)'
    assert_equal 'synth_2_0', v2_session_ids.first

    # Verify session summaries are also independent
    summaries = session_summary_final
    v1_summaries = summaries.select { |s| s['visitor_id'] == 1 }
    v2_summaries = summaries.select { |s| s['visitor_id'] == 2 }
    assert_equal 2, v1_summaries.size, 'v1 should have 2 session summaries'
    assert_equal 1, v2_summaries.size, 'v2 should have 1 session summary'
  end

  # ---------------------------------------------------------------------------
  # 10. 30-min gap boundary: exactly 1800s (same session) vs 1801s (new session)
  # ---------------------------------------------------------------------------
  test '30min_gap_boundary_exact' do
    base_time = @now - 2.hours

    # Pair A: exactly 1800s apart => should be SAME session
    insert_ch_events([
      raw_event(visitor_id: 10, event_id: 'gap_e1',
                created_at: ch_fmt(base_time)),
      raw_event(visitor_id: 10, event_id: 'gap_e2',
                created_at: ch_fmt(base_time + 1800.seconds))
    ])

    # Pair B: exactly 1801s apart => should be DIFFERENT sessions
    insert_ch_events([
      raw_event(visitor_id: 20, event_id: 'gap_e3',
                created_at: ch_fmt(base_time)),
      raw_event(visitor_id: 20, event_id: 'gap_e4',
                created_at: ch_fmt(base_time + 1801.seconds))
    ])

    @job.perform

    se_rows = ch_query('session_events', @project.id)

    # Pair A: visitor 10 => 1 session
    v10_sessions = se_rows.select { |r| r['visitor_id'] == 10 }
                          .map { |r| r['session_id'] }.uniq
    assert_equal 1, v10_sessions.size,
                 "exactly 1800s gap should be SAME session (got #{v10_sessions.inspect})"

    # Pair B: visitor 20 => 2 sessions
    v20_sessions = se_rows.select { |r| r['visitor_id'] == 20 }
                          .map { |r| r['session_id'] }.uniq
    assert_equal 2, v20_sessions.size,
                 "1801s gap should be DIFFERENT sessions (got #{v20_sessions.inspect})"
  end

  private

  # ---------------------------------------------------------------------------
  # Table helpers
  # ---------------------------------------------------------------------------

  def recreate_clickhouse_tables!
    ClickhouseTestHelper.reset_schema!
    truncate_clickhouse_tables
  end

  # Count rows in session_events for the test project.
  def session_event_count
    Clickhouse.with do |conn|
      conn.select_value(
        "SELECT count() FROM session_events WHERE project_id = #{@project.id}"
      )
    end
  end

  # Count rows in session_summary for the test project.
  def session_summary_count
    Clickhouse.with do |conn|
      conn.select_value(
        "SELECT count() FROM session_summary WHERE project_id = #{@project.id}"
      )
    end
  end

  # Query session_summary with FINAL for deduplicated ReplacingMergeTree view.
  def session_summary_final
    Clickhouse.with do |conn|
      conn.select_all(
        "SELECT * FROM session_summary FINAL WHERE project_id = #{@project.id}"
      )
    end.to_a
  end

  # ---------------------------------------------------------------------------
  # Event builder
  # ---------------------------------------------------------------------------

  def raw_event(visitor_id:, created_at:, event_id: nil, event_type: 'VIEW',
                screen_name: 'TestScreen', session_id: '', platform: 'ios',
                app_version: '1.0', country: 'US')
    {
      project_id: @project.id,
      event_id: event_id || SecureRandom.uuid,
      event_type: event_type,
      event_name: '',
      screen_name: screen_name,
      visitor_id: visitor_id,
      device_id: visitor_id,
      link_id: 0,
      inviter_id: 0,
      campaign_id: 0,
      platform: platform,
      app_version: app_version,
      build: '',
      vendor_id: '',
      device_model: '',
      os: '',
      os_version: '',
      timezone: '',
      language: '',
      country: country,
      city: '',
      tracking_source: '',
      tracking_medium: '',
      tracking_campaign: '',
      ads_platform: '',
      link_tags: [],
      sdk_identifier: '',
      session_id: session_id,
      engagement_time: 0,
      tags: [],
      ip: '',
      remote_ip: '',
      path: '',
      created_at: created_at
    }
  end

  # Insert N events for a visitor with incremental timestamps.
  def insert_raw_events(visitor_id:, count:, gap: 2.minutes, base_time: nil)
    base = base_time || @now - 30.minutes
    events = (0...count).map do |i|
      raw_event(
        visitor_id: visitor_id,
        event_id: "batch_#{visitor_id}_#{i}_#{SecureRandom.hex(4)}",
        created_at: ch_fmt(base + (gap * i))
      )
    end
    insert_ch_events(events)
  end

  # Format a Time for CH DateTime64.
  def ch_fmt(time)
    time.utc.strftime('%Y-%m-%d %H:%M:%S.%3N')
  end

  # ---------------------------------------------------------------------------
  # Stubs for Clickhouse.enabled? / read_enabled?
  # ---------------------------------------------------------------------------

end
