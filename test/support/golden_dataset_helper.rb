# frozen_string_literal: true

# Shared base dataset for all ClickHouse golden tests. Provides a frozen time
# anchor, deterministic visitor/session/event IDs, and the complete dataset
# described in docs/plans/2026-05-11-clickhouse-golden-tests-design.md section 2.
#
# Include this module in any test class that also includes ClickhouseTestHelper.
# Call setup_golden_dataset in setup and teardown_golden_dataset in teardown.
#
# The dataset has two projects:
#   P1 (golden)  = projects(:one)  -- 27 events, 5 visitors, 10 sessions
#   P2 (decoy)   = projects(:two)  -- 5 events, 1 visitor, 1 session
#
# Decoy data exists solely to catch project-filter leaks. Every golden test
# must assert no decoy IDs appear in results.
module GoldenDatasetHelper
  FROZEN_TIME = Time.utc(2026, 5, 1, 12, 0, 0)

  # ---------------------------------------------------------------------------
  # Deterministic ID generators
  # ---------------------------------------------------------------------------

  def golden_visitor(n)
    1000 + n
  end

  def decoy_visitor(n)
    9000 + n
  end

  # ---------------------------------------------------------------------------
  # Time helpers
  # ---------------------------------------------------------------------------

  # Returns a CH-formatted DateTime64 string at FROZEN_TIME + offset.
  def golden_time(offset)
    fmt(FROZEN_TIME + offset)
  end

  # Formats an arbitrary Time for CH DateTime64.
  def fmt(time)
    time.utc.strftime(Analytics::QueryHelpers::CH_DATETIME_FMT)
  end

  # ---------------------------------------------------------------------------
  # Project ID accessors (resolved from fixtures at test time)
  # ---------------------------------------------------------------------------

  def golden_project_id
    projects(:one).id
  end

  def decoy_project_id
    projects(:two).id
  end

  # Convenience accessors returning full AR objects (used by some tests).
  def golden_project
    @golden_project_record ||= projects(:one)
  end

  def decoy_project
    @decoy_project_record ||= projects(:two)
  end

  # Standard 7-day date range covering all base events.
  # Services use created_at >= start_date AND created_at < end_date + 1.day
  def golden_start_date
    (FROZEN_TIME.to_date - 7).to_s
  end

  def golden_end_date
    (FROZEN_TIME.to_date - 1).to_s
  end

  # ---------------------------------------------------------------------------
  # Setup / Teardown
  # ---------------------------------------------------------------------------

  def setup_golden_dataset
    travel_to(FROZEN_TIME)
    truncate_clickhouse_tables
    insert_golden_base_dataset
  end

  def teardown_golden_dataset
    travel_back
    @golden_project_record = nil
    @decoy_project_record = nil
  end

  # ---------------------------------------------------------------------------
  # Base dataset insertion -- populates all 5 CH table families
  # ---------------------------------------------------------------------------

  def insert_golden_base_dataset
    pid  = golden_project_id
    dpid = decoy_project_id

    insert_p1_events(pid)
    insert_p2_decoy_events(dpid)
    insert_p1_session_events(pid)
    insert_p1_session_summaries(pid)
    insert_p1_user_profiles(pid)
    insert_p1_visitor_daily(pid)
    insert_p2_decoy_derived(dpid)
  end

  # ---------------------------------------------------------------------------
  # Decoy Assertion Helpers
  # ---------------------------------------------------------------------------
  # These verify that project-filter isolation is working. Call them on any
  # result set that exposes the relevant key.

  # Asserts no visitor_id in results is in the decoy range (>= 9000).
  def assert_no_decoy_visitors(results, visitor_key: 'visitor_id')
    Array(results).each do |row|
      vid = row[visitor_key] || row[visitor_key.to_sym]
      next if vid.nil?

      assert vid.to_i < 9000,
             "Decoy visitor #{vid} leaked into results (row: #{row.inspect})"
    end
  end

  # Asserts no session_id in results starts with 'decoy_'.
  def assert_no_decoy_sessions(results, session_key: 'session_id')
    Array(results).each do |row|
      sid = row[session_key] || row[session_key.to_sym]
      next if sid.nil?

      refute sid.to_s.start_with?('decoy_'),
             "Decoy session #{sid} leaked into results (row: #{row.inspect})"
    end
  end

  # Asserts no event_id in results starts with 'decoy_'.
  def assert_no_decoy_events(results, event_key: 'event_id')
    Array(results).each do |row|
      eid = row[event_key] || row[event_key.to_sym]
      next if eid.nil?

      refute eid.to_s.start_with?('decoy_'),
             "Decoy event #{eid} leaked into results (row: #{row.inspect})"
    end
  end

  # Asserts all project_id values in results equal the golden project ID.
  def assert_no_decoy_project(results, project_key: 'project_id')
    gpid = golden_project_id
    Array(results).each do |row|
      rpid = row[project_key] || row[project_key.to_sym]
      next if rpid.nil?

      assert_equal gpid, rpid.to_i,
                   "Decoy project #{rpid} leaked into results (expected #{gpid}, row: #{row.inspect})"
    end
  end

  # Backwards-compatible bang aliases used by existing tests.
  alias assert_no_decoy_visitors! assert_no_decoy_visitors
  alias assert_no_decoy_events! assert_no_decoy_events
  alias assert_no_decoy_sessions! assert_no_decoy_sessions

  private

  # ===========================================================================
  # P1 Events -- 27 rows, 5 visitors, 4 platforms, all 8 event types
  # ===========================================================================
  #
  # Offsets from FROZEN_TIME (2026-05-01 12:00:00 UTC):
  #   -7d  = Apr 24 12:00    -6d = Apr 25 12:00    -5d = Apr 26 12:00
  #   -4d  = Apr 27 12:00    -3d = Apr 28 12:00    -2d = Apr 29 12:00
  #   -1d  = Apr 30 12:00
  #
  # Event# | Visitor | Type           | screen_name    | platform | ver | country | session    | offset
  # -------|---------|----------------|----------------|----------|-----|---------|------------|--------
  #   1    | v1      | INSTALL        | --             | ios      | 2.0 | US      | sess_v1_1  | -7d
  #   2    | v1      | OPEN           | HomeScreen     | ios      | 2.0 | US      | sess_v1_1  | -7d+1m
  #   3    | v1      | VIEW           | --             | ios      | 2.0 | US      | sess_v1_1  | -7d+2m
  #   4    | v1      | TIME_SPENT     | HomeScreen     | ios      | 2.0 | US      | sess_v1_1  | -7d+3m
  #   5    | v1      | OPEN           | SettingsScreen | ios      | 2.0 | US      | sess_v1_2  | -3d
  #   6    | v1      | APP_OPEN       | --             | ios      | 2.0 | US      | sess_v1_2  | -3d+1m
  #   7    | v1      | OPEN           | HomeScreen     | ios      | 2.0 | US      | sess_v1_3  | -1d
  #   8    | v2      | INSTALL        | --             | android  | 1.9 | DE      | sess_v2_1  | -5d
  #   9    | v2      | OPEN           | HomeScreen     | android  | 1.9 | DE      | sess_v2_1  | -5d+1m
  #  10    | v2      | OPEN           | LoginScreen    | android  | 1.9 | DE      | sess_v2_1  | -5d+2m
  #  11    | v2      | OPEN           | CheckoutScreen | android  | 1.9 | DE      | sess_v2_1  | -5d+3m
  #  12    | v2      | REINSTALL      | --             | android  | 2.0 | DE      | sess_v2_2  | -2d
  #  13    | v2      | OPEN           | HomeScreen     | android  | 2.0 | DE      | sess_v2_2  | -2d+1m
  #  14    | v2      | REACTIVATION   | --             | android  | 2.0 | DE      | sess_v2_2  | -2d+2m
  #  15    | v3      | VIEW           | --             | web      | --  | US      | sess_v3_1  | -4d
  #  16    | v3      | VIEW           | --             | web      | --  | US      | sess_v3_1  | -4d+30s
  #  17    | v3      | OPEN           | LandingPage    | web      | --  | US      | sess_v3_1  | -4d+1m
  #  18    | v3      | VIEW           | --             | web      | --  | FR      | sess_v3_2  | -1d
  #  19    | v3      | OPEN           | PricingPage    | web      | --  | FR      | sess_v3_2  | -1d+1m
  #  20    | v4      | INSTALL        | --             | ios      | 2.0 | US      | sess_v4_1  | -6d
  #  21    | v4      | OPEN           | HomeScreen     | ios      | 2.0 | US      | sess_v4_1  | -6d+1m
  #  22    | v4      | OPEN           | CheckoutScreen | ios      | 2.0 | US      | sess_v4_1  | -6d+2m
  #  23    | v4      | USER_REFERRED  | --             | ios      | 2.0 | US      | sess_v4_1  | -6d+3m
  #  24    | v5      | INSTALL        | --             | desktop  | 3.0 | GB      | sess_v5_1  | -3d
  #  25    | v5      | OPEN           | Dashboard      | desktop  | 3.0 | GB      | sess_v5_1  | -3d+1m
  #  26    | v5      | TIME_SPENT     | Dashboard      | desktop  | 3.0 | GB      | sess_v5_1  | -3d+5m
  #  27    | v5      | APP_OPEN       | --             | desktop  | 3.0 | GB      | sess_v5_2  | -1d
  #
  # Events per day for volume bucket tests:
  #   Day -7 (Apr 24): v1 events 1-4                   = 4 events
  #   Day -6 (Apr 25): v4 events 20-23                 = 4 events
  #   Day -5 (Apr 26): v2 events 8-11                  = 4 events
  #   Day -4 (Apr 27): v3 events 15-17                 = 3 events
  #   Day -3 (Apr 28): v1 events 5-6, v5 events 24-26 = 5 events
  #   Day -2 (Apr 29): v2 events 12-14                 = 3 events
  #   Day -1 (Apr 30): v1 event 7, v3 events 18-19, v5 event 27 = 4 events
  #   Total: 27

  def insert_p1_events(pid)
    v1 = golden_visitor(1)
    v2 = golden_visitor(2)
    v3 = golden_visitor(3)
    v4 = golden_visitor(4)
    v5 = golden_visitor(5)

    events = [
      # -- v1: ios, 2.0, US -- 3 sessions across days -7, -3, -1 (7 events) --
      evt(pid,  1, 'INSTALL',       '',               v1, 'ios', '2.0', 'US', 'sess_v1_1', -7.days),
      evt(pid,  2, 'OPEN',          'HomeScreen',     v1, 'ios', '2.0', 'US', 'sess_v1_1', -7.days + 1.minute),
      evt(pid,  3, 'VIEW',          '',               v1, 'ios', '2.0', 'US', 'sess_v1_1', -7.days + 2.minutes),
      evt(pid,  4, 'TIME_SPENT',    'HomeScreen',     v1, 'ios', '2.0', 'US', 'sess_v1_1', -7.days + 3.minutes),
      evt(pid,  5, 'OPEN',          'SettingsScreen', v1, 'ios', '2.0', 'US', 'sess_v1_2', -3.days),
      evt(pid,  6, 'APP_OPEN',      '',               v1, 'ios', '2.0', 'US', 'sess_v1_2', -3.days + 1.minute),
      evt(pid,  7, 'OPEN',          'HomeScreen',     v1, 'ios', '2.0', 'US', 'sess_v1_3', -1.day),

      # -- v2: android, 1.9->2.0, DE -- 2 sessions across days -5, -2 (7 events) --
      evt(pid,  8, 'INSTALL',       '',               v2, 'android', '1.9', 'DE', 'sess_v2_1', -5.days),
      evt(pid,  9, 'OPEN',          'HomeScreen',     v2, 'android', '1.9', 'DE', 'sess_v2_1', -5.days + 1.minute),
      evt(pid, 10, 'OPEN',          'LoginScreen',    v2, 'android', '1.9', 'DE', 'sess_v2_1', -5.days + 2.minutes),
      evt(pid, 11, 'OPEN',          'CheckoutScreen', v2, 'android', '1.9', 'DE', 'sess_v2_1', -5.days + 3.minutes),
      evt(pid, 12, 'REINSTALL',     '',               v2, 'android', '2.0', 'DE', 'sess_v2_2', -2.days),
      evt(pid, 13, 'OPEN',          'HomeScreen',     v2, 'android', '2.0', 'DE', 'sess_v2_2', -2.days + 1.minute),
      evt(pid, 14, 'REACTIVATION',  '',               v2, 'android', '2.0', 'DE', 'sess_v2_2', -2.days + 2.minutes),

      # -- v3: web, no version, US/FR -- 2 sessions across days -4, -1 (5 events) --
      evt(pid, 15, 'VIEW',          '',               v3, 'web', '', 'US', 'sess_v3_1', -4.days),
      evt(pid, 16, 'VIEW',          '',               v3, 'web', '', 'US', 'sess_v3_1', -4.days + 30.seconds),
      evt(pid, 17, 'OPEN',          'LandingPage',    v3, 'web', '', 'US', 'sess_v3_1', -4.days + 1.minute),
      evt(pid, 18, 'VIEW',          '',               v3, 'web', '', 'FR', 'sess_v3_2', -1.day),
      evt(pid, 19, 'OPEN',          'PricingPage',    v3, 'web', '', 'FR', 'sess_v3_2', -1.day + 1.minute),

      # -- v4: ios, 2.0, US -- 1 session on day -6 (4 events) --
      evt(pid, 20, 'INSTALL',       '',               v4, 'ios', '2.0', 'US', 'sess_v4_1', -6.days),
      evt(pid, 21, 'OPEN',          'HomeScreen',     v4, 'ios', '2.0', 'US', 'sess_v4_1', -6.days + 1.minute),
      evt(pid, 22, 'OPEN',          'CheckoutScreen', v4, 'ios', '2.0', 'US', 'sess_v4_1', -6.days + 2.minutes),
      evt(pid, 23, 'USER_REFERRED', '',               v4, 'ios', '2.0', 'US', 'sess_v4_1', -6.days + 3.minutes),

      # -- v5: desktop, 3.0, GB -- 2 sessions across days -3, -1 (4 events) --
      evt(pid, 24, 'INSTALL',       '',               v5, 'desktop', '3.0', 'GB', 'sess_v5_1', -3.days),
      evt(pid, 25, 'OPEN',          'Dashboard',      v5, 'desktop', '3.0', 'GB', 'sess_v5_1', -3.days + 1.minute),
      evt(pid, 26, 'TIME_SPENT',    'Dashboard',      v5, 'desktop', '3.0', 'GB', 'sess_v5_1', -3.days + 5.minutes),
      evt(pid, 27, 'APP_OPEN',      '',               v5, 'desktop', '3.0', 'GB', 'sess_v5_2', -1.day)
    ]

    insert_ch_events(events)
  end

  # ===========================================================================
  # P2 Decoy Events -- 5 rows, 1 visitor, 1 session
  # ===========================================================================
  # v91 on ios: INSTALL + 2 OPENs + VIEW + TIME_SPENT.
  # Counts differ from P1 on every dimension so any leak is obvious.

  def insert_p2_decoy_events(dpid)
    dv = decoy_visitor(1)

    events = [
      evt(dpid, 1, 'INSTALL',    '',          dv, 'ios', '9.0', 'JP', 'decoy_sess_1', -5.days,              prefix: 'decoy'),
      evt(dpid, 2, 'OPEN',       'DecoyHome', dv, 'ios', '9.0', 'JP', 'decoy_sess_1', -5.days + 1.minute,  prefix: 'decoy'),
      evt(dpid, 3, 'OPEN',       'DecoyCart', dv, 'ios', '9.0', 'JP', 'decoy_sess_1', -5.days + 2.minutes, prefix: 'decoy'),
      evt(dpid, 4, 'VIEW',       '',          dv, 'ios', '9.0', 'JP', 'decoy_sess_1', -5.days + 3.minutes, prefix: 'decoy'),
      evt(dpid, 5, 'TIME_SPENT', 'DecoyHome', dv, 'ios', '9.0', 'JP', 'decoy_sess_1', -5.days + 5.minutes, prefix: 'decoy')
    ]

    insert_ch_events(events)
  end

  # ===========================================================================
  # P1 Session Events -- only events with non-empty screen_name
  # ===========================================================================
  #
  # Session event mapping from raw events:
  #
  # sess_v1_1: evt#2 OPEN HomeScreen (-7d+1m), evt#4 TIME_SPENT HomeScreen (-7d+3m)
  #   Excluded: evt#1 INSTALL (no screen), evt#3 VIEW (no screen)
  #
  # sess_v1_2: evt#5 OPEN SettingsScreen (-3d)
  #   Excluded: evt#6 APP_OPEN (no screen)
  #
  # sess_v1_3: evt#7 OPEN HomeScreen (-1d)
  #
  # sess_v2_1: evt#9 OPEN HomeScreen (-5d+1m), evt#10 OPEN LoginScreen (-5d+2m),
  #            evt#11 OPEN CheckoutScreen (-5d+3m)
  #   Excluded: evt#8 INSTALL (no screen)
  #
  # sess_v2_2: evt#13 OPEN HomeScreen (-2d+1m)
  #   Excluded: evt#12 REINSTALL (no screen), evt#14 REACTIVATION (no screen)
  #
  # sess_v3_1: evt#17 OPEN LandingPage (-4d+1m)
  #   Excluded: evt#15 VIEW (no screen), evt#16 VIEW (no screen)
  #
  # sess_v3_2: evt#19 OPEN PricingPage (-1d+1m)
  #   Excluded: evt#18 VIEW (no screen)
  #
  # sess_v4_1: evt#21 OPEN HomeScreen (-6d+1m), evt#22 OPEN CheckoutScreen (-6d+2m)
  #   Excluded: evt#20 INSTALL (no screen), evt#23 USER_REFERRED (no screen)
  #
  # sess_v5_1: evt#25 OPEN Dashboard (-3d+1m), evt#26 TIME_SPENT Dashboard (-3d+5m)
  #   Excluded: evt#24 INSTALL (no screen)
  #
  # sess_v5_2: no screen_name events (only evt#27 APP_OPEN without screen)
  #
  # Total session_events rows: 2 + 1 + 1 + 3 + 1 + 1 + 1 + 2 + 2 = 14

  def insert_p1_session_events(pid)
    v1 = golden_visitor(1)
    v2 = golden_visitor(2)
    v3 = golden_visitor(3)
    v4 = golden_visitor(4)
    v5 = golden_visitor(5)

    rows = [
      # sess_v1_1: HomeScreen(OPEN) + HomeScreen(TIME_SPENT)
      se(pid, 'sess_v1_1', v1,  2, 'OPEN',       'HomeScreen',     'ios',     '2.0', 'US', -7.days + 1.minute),
      se(pid, 'sess_v1_1', v1,  4, 'TIME_SPENT',  'HomeScreen',     'ios',     '2.0', 'US', -7.days + 3.minutes),

      # sess_v1_2: SettingsScreen(OPEN) — referral
      se(pid, 'sess_v1_2', v1,  5, 'OPEN',       'SettingsScreen', 'ios',     '2.0', 'US', -3.days,
         sdk_generated: 1, link_visitor_id: 8888),

      # sess_v1_3: HomeScreen(OPEN)
      se(pid, 'sess_v1_3', v1,  7, 'OPEN',       'HomeScreen',     'ios',     '2.0', 'US', -1.day),

      # sess_v2_1: HomeScreen(OPEN) + LoginScreen(OPEN) + CheckoutScreen(OPEN) — campaign
      se(pid, 'sess_v2_1', v2,  9, 'OPEN',       'HomeScreen',     'android', '1.9', 'DE', -5.days + 1.minute,
         campaign_id: 99, link_id: 99),
      se(pid, 'sess_v2_1', v2, 10, 'OPEN',       'LoginScreen',    'android', '1.9', 'DE', -5.days + 2.minutes,
         campaign_id: 99, link_id: 99),
      se(pid, 'sess_v2_1', v2, 11, 'OPEN',       'CheckoutScreen', 'android', '1.9', 'DE', -5.days + 3.minutes,
         campaign_id: 99, link_id: 99),

      # sess_v2_2: HomeScreen(OPEN)
      se(pid, 'sess_v2_2', v2, 13, 'OPEN',       'HomeScreen',     'android', '2.0', 'DE', -2.days + 1.minute),

      # sess_v3_1: LandingPage(OPEN) — referral
      se(pid, 'sess_v3_1', v3, 17, 'OPEN',       'LandingPage',    'web',     '',    'US', -4.days + 1.minute,
         sdk_generated: 1, link_visitor_id: 8888),

      # sess_v3_2: PricingPage(OPEN) — link
      se(pid, 'sess_v3_2', v3, 19, 'OPEN',       'PricingPage',    'web',     '',    'FR', -1.day + 1.minute,
         link_id: 55),

      # sess_v4_1: HomeScreen(OPEN) + CheckoutScreen(OPEN) — campaign
      se(pid, 'sess_v4_1', v4, 21, 'OPEN',       'HomeScreen',     'ios',     '2.0', 'US', -6.days + 1.minute,
         campaign_id: 99, link_id: 99),
      se(pid, 'sess_v4_1', v4, 22, 'OPEN',       'CheckoutScreen', 'ios',     '2.0', 'US', -6.days + 2.minutes,
         campaign_id: 99, link_id: 99),

      # sess_v5_1: Dashboard(OPEN) + Dashboard(TIME_SPENT) — API link
      se(pid, 'sess_v5_1', v5, 25, 'OPEN',       'Dashboard',      'desktop', '3.0', 'GB', -3.days + 1.minute,
         sdk_generated: 1, link_id: 77),
      se(pid, 'sess_v5_1', v5, 26, 'TIME_SPENT',  'Dashboard',      'desktop', '3.0', 'GB', -3.days + 5.minutes,
         sdk_generated: 1, link_id: 77)

      # sess_v5_2: no screen_name events -- excluded from session_events entirely
    ]

    insert_ch_session_events(rows)
  end

  # ===========================================================================
  # P1 Session Summaries -- 10 sessions with hand-calculated values
  # ===========================================================================
  #
  # Fields derived from each session:
  #   screen_count  = count of DISTINCT screen_name values in session_events for this session
  #   event_count   = total number of session_event rows for this session
  #   duration_ms   = (last raw event timestamp - first raw event timestamp) in milliseconds
  #   first_screen  = screen_name of first session_event (chronologically)
  #   last_screen   = screen_name of last session_event (chronologically)
  #   has_conversion = 1 if session contains CheckoutScreen (matches "checkout" conversion pattern)
  #   tracking_source = '' for all base data
  #   started_at    = created_at of first raw event in session
  #   ended_at      = created_at of last raw event in session
  #
  # --------------------------------------------------------------------------
  # sess_v1_1 (v1, ios, -7d):
  #   Raw events: #1(-7d), #2(-7d+1m), #3(-7d+2m), #4(-7d+3m)
  #   Session events: #2 HomeScreen(OPEN), #4 HomeScreen(TIME_SPENT)
  #   screen_count = 1 (HomeScreen)
  #   event_count  = 2
  #   duration_ms  = 3 min * 60_000 = 180_000
  #   first_screen = HomeScreen, last_screen = HomeScreen
  #   has_conversion = 0
  #
  # sess_v1_2 (v1, ios, -3d):
  #   Raw events: #5(-3d), #6(-3d+1m)
  #   Session events: #5 SettingsScreen(OPEN)
  #   screen_count = 1 (SettingsScreen)
  #   event_count  = 1
  #   duration_ms  = 1 min * 60_000 = 60_000
  #   first_screen = SettingsScreen, last_screen = SettingsScreen
  #   has_conversion = 0
  #
  # sess_v1_3 (v1, ios, -1d):
  #   Raw events: #7(-1d)
  #   Session events: #7 HomeScreen(OPEN)
  #   screen_count = 1 (HomeScreen)
  #   event_count  = 1
  #   duration_ms  = 0 (single raw event)
  #   first_screen = HomeScreen, last_screen = HomeScreen
  #   has_conversion = 0
  #
  # sess_v2_1 (v2, android, -5d):
  #   Raw events: #8(-5d), #9(-5d+1m), #10(-5d+2m), #11(-5d+3m)
  #   Session events: #9 HomeScreen, #10 LoginScreen, #11 CheckoutScreen
  #   screen_count = 3 (HomeScreen, LoginScreen, CheckoutScreen)
  #   event_count  = 3
  #   duration_ms  = 3 min * 60_000 = 180_000
  #   first_screen = HomeScreen, last_screen = CheckoutScreen
  #   has_conversion = 1 (CheckoutScreen matches "checkout")
  #
  # sess_v2_2 (v2, android, -2d):
  #   Raw events: #12(-2d), #13(-2d+1m), #14(-2d+2m)
  #   Session events: #13 HomeScreen(OPEN)
  #   screen_count = 1 (HomeScreen)
  #   event_count  = 1
  #   duration_ms  = 2 min * 60_000 = 120_000
  #   first_screen = HomeScreen, last_screen = HomeScreen
  #   has_conversion = 0
  #
  # sess_v3_1 (v3, web, -4d):
  #   Raw events: #15(-4d), #16(-4d+30s), #17(-4d+1m)
  #   Session events: #17 LandingPage(OPEN)
  #   screen_count = 1 (LandingPage)
  #   event_count  = 1
  #   duration_ms  = 1 min * 60_000 = 60_000
  #   first_screen = LandingPage, last_screen = LandingPage
  #   has_conversion = 0
  #
  # sess_v3_2 (v3, web, -1d):
  #   Raw events: #18(-1d), #19(-1d+1m)
  #   Session events: #19 PricingPage(OPEN)
  #   screen_count = 1 (PricingPage)
  #   event_count  = 1
  #   duration_ms  = 1 min * 60_000 = 60_000
  #   first_screen = PricingPage, last_screen = PricingPage
  #   has_conversion = 0
  #
  # sess_v4_1 (v4, ios, -6d):
  #   Raw events: #20(-6d), #21(-6d+1m), #22(-6d+2m), #23(-6d+3m)
  #   Session events: #21 HomeScreen, #22 CheckoutScreen
  #   screen_count = 2 (HomeScreen, CheckoutScreen)
  #   event_count  = 2
  #   duration_ms  = 3 min * 60_000 = 180_000
  #   first_screen = HomeScreen, last_screen = CheckoutScreen
  #   has_conversion = 1 (CheckoutScreen matches "checkout")
  #
  # sess_v5_1 (v5, desktop, -3d):
  #   Raw events: #24(-3d), #25(-3d+1m), #26(-3d+5m)
  #   Session events: #25 Dashboard(OPEN), #26 Dashboard(TIME_SPENT)
  #   screen_count = 1 (Dashboard)
  #   event_count  = 2
  #   duration_ms  = 5 min * 60_000 = 300_000
  #   first_screen = Dashboard, last_screen = Dashboard
  #   has_conversion = 0
  #
  # sess_v5_2 (v5, desktop, -1d):
  #   Raw events: #27(-1d)
  #   Session events: none
  #   screen_count = 0
  #   event_count  = 0
  #   duration_ms  = 0 (single raw event, no session_events)
  #   first_screen = '', last_screen = ''
  #   has_conversion = 0

  def insert_p1_session_summaries(pid)
    v1 = golden_visitor(1)
    v2 = golden_visitor(2)
    v3 = golden_visitor(3)
    v4 = golden_visitor(4)
    v5 = golden_visitor(5)

    summaries = [
      ss(pid, 'sess_v1_1', v1, 'ios',     '2.0', 'US',
         screen_count: 1, event_count: 2, duration_ms: 180_000,
         first_screen: 'HomeScreen', last_screen: 'HomeScreen', has_conversion: 0,
         started_at: -7.days, ended_at: -7.days + 3.minutes),

      ss(pid, 'sess_v1_2', v1, 'ios',     '2.0', 'US',
         screen_count: 1, event_count: 1, duration_ms: 60_000,
         first_screen: 'SettingsScreen', last_screen: 'SettingsScreen', has_conversion: 0,
         started_at: -3.days, ended_at: -3.days + 1.minute,
         sdk_generated: 1, link_visitor_id: 8888),

      ss(pid, 'sess_v1_3', v1, 'ios',     '2.0', 'US',
         screen_count: 1, event_count: 1, duration_ms: 0,
         first_screen: 'HomeScreen', last_screen: 'HomeScreen', has_conversion: 0,
         started_at: -1.day, ended_at: -1.day),

      ss(pid, 'sess_v2_1', v2, 'android', '1.9', 'DE',
         screen_count: 3, event_count: 3, duration_ms: 180_000,
         first_screen: 'HomeScreen', last_screen: 'CheckoutScreen', has_conversion: 1,
         started_at: -5.days, ended_at: -5.days + 3.minutes,
         campaign_id: 99, link_id: 99),

      ss(pid, 'sess_v2_2', v2, 'android', '2.0', 'DE',
         screen_count: 1, event_count: 1, duration_ms: 120_000,
         first_screen: 'HomeScreen', last_screen: 'HomeScreen', has_conversion: 0,
         started_at: -2.days, ended_at: -2.days + 2.minutes),

      ss(pid, 'sess_v3_1', v3, 'web',     '',    'US',
         screen_count: 1, event_count: 1, duration_ms: 60_000,
         first_screen: 'LandingPage', last_screen: 'LandingPage', has_conversion: 0,
         started_at: -4.days, ended_at: -4.days + 1.minute,
         sdk_generated: 1, link_visitor_id: 8888),

      ss(pid, 'sess_v3_2', v3, 'web',     '',    'FR',
         screen_count: 1, event_count: 1, duration_ms: 60_000,
         first_screen: 'PricingPage', last_screen: 'PricingPage', has_conversion: 0,
         started_at: -1.day, ended_at: -1.day + 1.minute,
         link_id: 55),

      ss(pid, 'sess_v4_1', v4, 'ios',     '2.0', 'US',
         screen_count: 2, event_count: 2, duration_ms: 180_000,
         first_screen: 'HomeScreen', last_screen: 'CheckoutScreen', has_conversion: 1,
         started_at: -6.days, ended_at: -6.days + 3.minutes,
         campaign_id: 99, link_id: 99),

      ss(pid, 'sess_v5_1', v5, 'desktop', '3.0', 'GB',
         screen_count: 1, event_count: 2, duration_ms: 300_000,
         first_screen: 'Dashboard', last_screen: 'Dashboard', has_conversion: 0,
         started_at: -3.days, ended_at: -3.days + 5.minutes,
         sdk_generated: 1, link_id: 77),

      ss(pid, 'sess_v5_2', v5, 'desktop', '3.0', 'GB',
         screen_count: 0, event_count: 0, duration_ms: 0,
         first_screen: '', last_screen: '', has_conversion: 0,
         started_at: -1.day, ended_at: -1.day)
    ]

    insert_ch_session_summaries(summaries)
  end

  # ===========================================================================
  # P1 User Profiles -- 5 rows (one per visitor)
  # ===========================================================================
  #
  # first_seen / last_seen derived from earliest/latest raw event per visitor.
  # platform from first event.
  #
  # v1 (ios, US):     first_seen = -7d,  last_seen = -1d
  # v2 (android, DE): first_seen = -5d,  last_seen = -2d
  # v3 (web, US):     first_seen = -4d,  last_seen = -1d
  # v4 (ios, US):     first_seen = -6d,  last_seen = -6d
  # v5 (desktop, GB): first_seen = -3d,  last_seen = -1d

  def insert_p1_user_profiles(pid)
    profiles = [
      up(pid, golden_visitor(1), 'ios',     'US', -7.days,  -1.day),
      up(pid, golden_visitor(2), 'android', 'DE', -5.days,  -2.days),
      up(pid, golden_visitor(3), 'web',     'US', -4.days,  -1.day),
      up(pid, golden_visitor(4), 'ios',     'US', -6.days,  -6.days),
      up(pid, golden_visitor(5), 'desktop', 'GB', -3.days,  -1.day)
    ]

    insert_ch_user_profiles(profiles)
  end

  # ===========================================================================
  # P1 Visitor Daily -- one row per visitor per active day
  # ===========================================================================
  #
  # Active days derived from raw events:
  #   v1 (ios):     -7d (4 events), -3d (2 events), -1d (1 event)
  #   v2 (android): -5d (4 events), -2d (3 events)
  #   v3 (web):     -4d (3 events), -1d (2 events)
  #   v4 (ios):     -6d (4 events)
  #   v5 (desktop): -3d (3 events), -1d (1 event)
  #
  # event_type = 'OPEN' as representative type.
  # total_engagement_time = 0 for base data.
  # inviter_id_state = 0 for base data.

  def insert_p1_visitor_daily(pid)
    rows = [
      # v1 active days
      vd(pid, golden_visitor(1), 'ios',     -7.days, 4),
      vd(pid, golden_visitor(1), 'ios',     -3.days, 2),
      vd(pid, golden_visitor(1), 'ios',     -1.day,  1),

      # v2 active days
      vd(pid, golden_visitor(2), 'android', -5.days, 4),
      vd(pid, golden_visitor(2), 'android', -2.days, 3),

      # v3 active days
      vd(pid, golden_visitor(3), 'web',     -4.days, 3),
      vd(pid, golden_visitor(3), 'web',     -1.day,  2),

      # v4 active days
      vd(pid, golden_visitor(4), 'ios',     -6.days, 4),

      # v5 active days
      vd(pid, golden_visitor(5), 'desktop', -3.days, 3),
      vd(pid, golden_visitor(5), 'desktop', -1.day,  1)
    ]

    insert_ch_visitor_daily(rows)
  end

  # ===========================================================================
  # P2 Decoy Derived Tables
  # ===========================================================================

  def insert_p2_decoy_derived(dpid)
    dv = decoy_visitor(1)

    # Decoy session events: 3 events with screen_name
    # From 5 raw events: evt#2 OPEN DecoyHome, evt#3 OPEN DecoyCart, evt#5 TIME_SPENT DecoyHome
    # Excluded: evt#1 INSTALL (no screen), evt#4 VIEW (no screen)
    insert_ch_session_events([
      se(dpid, 'decoy_sess_1', dv, 2, 'OPEN',       'DecoyHome', 'ios', '9.0', 'JP', -5.days + 1.minute,  prefix: 'decoy'),
      se(dpid, 'decoy_sess_1', dv, 3, 'OPEN',       'DecoyCart', 'ios', '9.0', 'JP', -5.days + 2.minutes, prefix: 'decoy'),
      se(dpid, 'decoy_sess_1', dv, 5, 'TIME_SPENT', 'DecoyHome', 'ios', '9.0', 'JP', -5.days + 5.minutes, prefix: 'decoy')
    ])

    # Decoy session summary: 1 session
    # screen_count = 2 (DecoyHome, DecoyCart), event_count = 3, duration_ms = 5min = 300_000
    insert_ch_session_summaries([
      ss(dpid, 'decoy_sess_1', dv, 'ios', '9.0', 'JP',
         screen_count: 2, event_count: 3, duration_ms: 300_000,
         first_screen: 'DecoyHome', last_screen: 'DecoyHome', has_conversion: 0,
         started_at: -5.days, ended_at: -5.days + 5.minutes)
    ])

    # Decoy user profile: 1 visitor
    insert_ch_user_profiles([
      up(dpid, dv, 'ios', 'JP', -5.days, -5.days)
    ])

    # Decoy visitor daily: 1 active day
    insert_ch_visitor_daily([
      vd(dpid, dv, 'ios', -5.days, 5)
    ])
  end

  # ===========================================================================
  # Row builder helpers -- construct hashes for CH insert methods
  # ===========================================================================

  # Build a raw event hash.
  def evt(project_id, n, event_type, screen_name, visitor_id,
          platform, app_version, country, session_id, offset,
          prefix: 'golden', sdk_generated: 0, link_visitor_id: 0)
    {
      project_id:  project_id,
      event_id:    "#{prefix}_evt_#{n}",
      event_type:  event_type,
      event_name:  '',
      screen_name: screen_name,
      visitor_id:  visitor_id,
      device_id:   visitor_id,
      link_id:     0,
      inviter_id:  0,
      campaign_id: 0,
      platform:    platform,
      app_version: app_version,
      build:       '',
      vendor_id:   '',
      device_model: '',
      os:          '',
      os_version:  '',
      timezone:    '',
      language:    '',
      country:     country,
      city:        '',
      tracking_source:   '',
      tracking_medium:   '',
      tracking_campaign: '',
      ads_platform:      '',
      link_tags:         [],
      sdk_identifier:    '',
      session_id:  session_id,
      engagement_time: 0,
      tags:        [],
      ip:          '',
      remote_ip:   '',
      path:        '',
      sdk_generated:   sdk_generated,
      link_visitor_id: link_visitor_id,
      created_at:  golden_time(offset)
    }
  end

  # Build a session_event hash.
  def se(project_id, session_id, visitor_id, evt_n, event_type, screen_name,
         platform, app_version, country, offset,
         prefix: 'golden', sdk_generated: 0, link_visitor_id: 0,
         link_id: 0, campaign_id: 0)
    {
      project_id:      project_id,
      session_id:      session_id,
      visitor_id:      visitor_id,
      device_id:       visitor_id,
      event_id:        "#{prefix}_evt_#{evt_n}",
      event_date:      (FROZEN_TIME + offset).to_date.to_s,
      event_type:      event_type,
      event_name:      '',
      screen_name:     screen_name,
      platform:        platform,
      app_version:     app_version,
      country:         country,
      device_model:    '',
      link_id:         link_id,
      campaign_id:     campaign_id,
      tracking_source: '',
      sdk_generated:   sdk_generated,
      link_visitor_id: link_visitor_id,
      engagement_time: 0,
      created_at:      golden_time(offset)
    }
  end

  # Build a session_summary hash.
  def ss(project_id, session_id, visitor_id, platform, app_version, country,
         screen_count:, event_count:, duration_ms:,
         first_screen:, last_screen:, has_conversion:,
         started_at:, ended_at:,
         sdk_generated: 0, link_visitor_id: 0, link_id: 0, campaign_id: 0)
    start_time = FROZEN_TIME + started_at
    end_time   = FROZEN_TIME + ended_at
    {
      project_id:        project_id,
      session_id:        session_id,
      visitor_id:        visitor_id,
      event_date:        start_time.to_date.to_s,
      platform:          platform,
      app_version:       app_version,
      country:           country,
      device_model:      '',
      tracking_source:   '',
      link_id:           link_id,
      campaign_id:       campaign_id,
      sdk_generated:     sdk_generated,
      link_visitor_id:   link_visitor_id,
      screen_count:      screen_count,
      event_count:       event_count,
      duration_ms:       duration_ms,
      first_screen:      first_screen,
      last_screen:       last_screen,
      has_conversion:    has_conversion,
      revenue_usd_cents: 0,
      started_at:        fmt(start_time),
      ended_at:          fmt(end_time)
    }
  end

  # Build a user_profiles hash.
  def up(project_id, visitor_id, platform, country, first_seen_offset, last_seen_offset)
    {
      project_id:     project_id,
      visitor_id:     visitor_id,
      sdk_identifier: '',
      first_seen:     fmt(FROZEN_TIME + first_seen_offset),
      last_seen:      fmt(FROZEN_TIME + last_seen_offset),
      country:        country,
      platform:       platform,
      inviter_id:     0
    }
  end

  # Build a visitor_daily hash.
  def vd(project_id, visitor_id, platform, offset, cnt)
    {
      project_id:            project_id,
      visitor_id:            visitor_id,
      event_date:            (FROZEN_TIME + offset).to_date.to_s,
      event_type:            'OPEN',
      platform:              platform,
      cnt:                   cnt,
      total_engagement_time: 0,
      inviter_id_state:      0
    }
  end
end
