# frozen_string_literal: true

require 'test_helper'

# Golden dataset tests for Analytics::RetentionService. Unlike other golden tests
# that use FROZEN_TIME (2026-05-01), retention tests use Time.current-relative
# timestamps because the RetentionService SQL uses CH `now()` which returns
# the ClickHouse server's wall clock, NOT Ruby's frozen time.
#
# This test class defines its own `insert_retention_golden_data` method that
# inserts user_profiles and visitor_daily rows with timestamps relative to
# Time.current, ensuring CH `now()` eligibility checks work correctly.
#
# ============================================================================
# Retention Dataset Design (all timestamps relative to Time.current)
# ============================================================================
#
# 5 core visitors + 5 extra visitors (10 total, for retention-rate denominators):
#
# Core visitors:
#   v1 (ios, US):     first_seen = now - 35d, active days: -35, -34, -28, -5, -1
#     -> D1 retained (day+1=-34d, active? yes)
#     -> D7 retained (day+7=-28d, active? yes)
#     -> D30 retained (day+30=-5d, active? yes)
#
#   v2 (android, DE): first_seen = now - 35d, active days: -35, -34, -28, -1
#     -> D1 retained (day+1=-34d, active? yes)
#     -> D7 retained (day+7=-28d, active? yes)
#     -> D30 retained (day+30=-5d, active? no) NOT retained D30
#
#   v3 (ios, US):     first_seen = now - 35d, active days: -35, -34, -28, -5
#     -> D1 retained (day+1=-34d, active? yes)
#     -> D7 retained (day+7=-28d, active? yes)
#     -> D30 retained (day+30=-5d, active? yes)
#
#   v4 (ios, US):     first_seen = now - 35d, active days: -35 only (churned)
#     -> D1 NOT retained
#     -> D7 NOT retained
#     -> D30 NOT retained
#
#   v5 (web, GB):     first_seen = now - 35d, active days: -35, -34, -1
#     -> D1 retained (day+1=-34d, active? yes)
#     -> D7 NOT retained (day+7=-28d, active? no)
#     -> D30 NOT retained (day+30=-5d, active? no)
#
# Summary calculations (all 10 visitors eligible for D1/D7/D30 since first_seen = now-35d):
#   D1:  eligible = 10, retained = all except v4 = 9.      Rate = 90.0%
#   D3:  eligible = 10, retained = v1,v2,v3,v5,v7,v8,v9,v10 = 8. Rate = 80.0%
#   D7:  eligible = 10, retained = v1,v2,v3,v5,v7,v8,v9,v10 = 8. Rate = 80.0%
#   D14: eligible = 10, retained = v1,v2,v3,v5,v9 = 5.    Rate = 50.0%
#   D30: eligible = 10, retained = v1,v2,v3,v5,v9 = 5.    Rate = 50.0%
#   D60: need first_seen <= now-60d. None qualify.          Rate = nil
#   D90: same.                                              Rate = nil
#
# Median churn day: first d where rate < 50 => none (all >= 50). Result = nil
#
# Extra visitors (v6-v10, all ios, first_seen = now-35d):
#   v6:  active days -35, -34 (HomeScreen on day -35). max_event_date=-34.
#   v7:  active days -35, -34, -28 (HomeScreen on day -35). max_event_date=-28.
#   v8:  active days -35, -28 (HomeScreen on day -35). max_event_date=-28.
#   v9:  active days -35, -34, -28, -5 (HomeScreen + SettingsScreen on day -35). max_event_date=-5.
#   v10: active days -35, -34, -28 (SettingsScreen only on day -35). max_event_date=-28.
#
# Decoy visitor (project_two):
#   dv1 (ios, JP): first_seen = now - 35d, active days: -35, -34, -28, -5, -1
#     Would be fully retained. If it leaks into P1 results, rates change.
#
# ============================================================================
# Cohort calculations (weekly granularity)
# ============================================================================
#
# All 10 visitors have first_seen = now-35d (same date), so they fall into one
# weekly cohort: the week starting on the Monday of (now-35d).
#
# Cohort total = 10, retained at each day column:
#   Day 0: 10 (all, by definition)
#   Day 1: visitors with max_event_date >= first_seen+1 = (now-34d)
#     v1(-1d), v2(-1d), v3(-5d), v5(-1d), v6(-34d), v7(-28d), v8(-28d), v9(-5d), v10(-28d) = 9
#     (v4 max=-35d, not >= -34d) => 9
#   Day 3: visitors with max_event_date >= first_seen+3 = (now-32d)
#     v1(-1d), v2(-1d), v3(-5d), v5(-1d), v7(-28d), v8(-28d), v9(-5d), v10(-28d) = 8
#     (v4 max=-35d no, v6 max=-34d no since -34 < -32) => 8
#   Day 7: visitors with max_event_date >= first_seen+7 = (now-28d)
#     v1(-1d), v2(-1d), v3(-5d), v5(-1d), v7(-28d), v8(-28d), v9(-5d), v10(-28d) = 8
#     (v4 max=-35d no, v6 max=-34d no since -34 < -28) => 8
#   Day 14: visitors with max_event_date >= first_seen+14 = (now-21d)
#     v1(-1d), v2(-1d), v3(-5d), v5(-1d), v9(-5d) = 5
#     (v4,-35 no; v6,-34 no; v7,-28 no; v8,-28 no; v10,-28 no) => 5
#   Day 30: visitors with max_event_date >= first_seen+30 = (now-5d)
#     v1(-1d yes), v2(-1d yes), v3(-5d yes), v5(-1d yes), v9(-5d yes) = 5
#     => 5
#
# ============================================================================
# Screen impact calculations (D7, baseline)
# ============================================================================
#
# Baseline D7: eligible = first_seen <= now-7d = all 10.
#   retained_d7 = max_event_date >= first_seen+7 = now-28d
#     v1(max=-1), v2(max=-1), v3(max=-5), v5(max=-1), v7(max=-28), v8(max=-28), v9(max=-5), v10(max=-28) = 8
#   baseline_rate = 8/10 * 100 = 80.0%
#
# Screen impact query joins session_events on first_seen date.
# Only screens seen on the visitor's first_seen date (now-35d) qualify.
# We insert session_events for:
#   HomeScreen on day -35: v1, v2, v3, v4, v6, v7, v8, v9 = 8 visitors
#     retained_d7 of those 8: v1,v2,v3,v7,v8,v9 = 6 (v4 max=-35 no, v6 max=-34 no)
#     rate = 6/8 * 100 = 75.0%, multiplier = 75.0/80.0 = 0.94 => churny
#
#   SettingsScreen on day -35: v9, v10 = 2 visitors
#     BELOW threshold of 5 => excluded from results
#
class Analytics::RetentionGoldenTest < ActiveSupport::TestCase
  include ClickhouseTestHelper
  include GoldenDatasetHelper

  fixtures :projects, :instances

  setup do
    skip_unless_clickhouse!
    @project = projects(:one)
    @decoy_project = projects(:two)
    insert_retention_golden_data
  end

  # No travel_back needed — we don't use travel_to for retention tests.

  # ==========================================================================
  # Summary tests
  # ==========================================================================

  # --------------------------------------------------------------------------
  # Test 1: Exact D1/D7/D30 retention rates
  # --------------------------------------------------------------------------
  #
  # From the 5 core visitors (all first_seen = now-35d, all eligible for D1/D7/D30):
  #   D1 retained: v1,v2,v3,v5 (4 of 5) = 80.0%
  #   D7 retained: v1,v2,v3 (3 of 5) = 60.0%
  #   D30 retained: v1,v3 (2 of 5) = 40.0%
  #
  # But wait — with 10 total visitors (5 core + 5 extra), all first_seen = now-35d:
  #   D1 eligible: 10. retained: v1,v2,v3,v5,v6,v7,v8,v9,v10 = 9 (v4 churned). Rate = 90.0%
  #   D7 eligible: 10. retained: v1,v2,v3,v5,v7,v8,v9,v10 = 8. Rate = 80.0%
  #   D30 eligible: 10. retained: v1,v2,v3,v5,v9 = 5. Rate = 50.0%
  #
  # D3: need max_event_date >= now-32d. v1,v2,v3,v5,v7,v8,v9,v10 = 8. Rate = 80.0%
  # D14: need max_event_date >= now-21d. v1,v2,v3,v5,v9 = 5. Rate = 50.0%
  # D60: eligible = first_seen <= now-60d. None. Rate = nil.
  # D90: same. Rate = nil.
  #
  # Median churn: first d where rate < 50 => none of [1,3,7,14,30] are < 50.
  #   d=1: 90.0, d=3: 80.0, d=7: 80.0, d=14: 50.0, d=30: 50.0 — all >= 50.
  #   d=60: nil, d=90: nil — nils are skipped by `&.< 50.0`.
  #   So median_churn_day = nil.
  test 'summary returns exact D1 D7 D30 rates' do
    result = Analytics::RetentionService.summary(@project.id)

    assert_equal 90.0, result[:day_1],  "D1 retention: 9 of 10 returned on day+1"
    assert_equal 80.0, result[:day_7],  "D7 retention: 8 of 10 returned by day+7"
    assert_equal 50.0, result[:day_30], "D30 retention: 5 of 10 returned by day+30"
  end

  # --------------------------------------------------------------------------
  # Test 2: Exact eligibility denominators and median churn
  # --------------------------------------------------------------------------
  test 'summary median churn day is nil when all rates are at or above 50 percent' do
    result = Analytics::RetentionService.summary(@project.id)

    # D1=90, D3=80, D7=80, D14=50, D30=50 — none < 50
    # D60/D90 = nil (no eligible visitors) — nil&.<(50) returns nil (falsy)
    assert_nil result[:median_churn_day],
               "No rate drops below 50%%, so median_churn_day should be nil"
  end

  # --------------------------------------------------------------------------
  # Test 3: Sparkline covers last 30 days of daily D1 rates
  # --------------------------------------------------------------------------
  #
  # Sparkline includes visitors with first_seen in [now-30d, now-1d].
  # All our visitors have first_seen = now-35d which is OUTSIDE this range.
  # So sparkline should be empty for the base dataset.
  test 'summary sparkline is empty when no visitors have first_seen in last 30 days' do
    result = Analytics::RetentionService.summary(@project.id)

    assert_equal [], result[:sparkline],
                 "No visitors have first_seen within [now-30d, now-1d]"
  end

  # --------------------------------------------------------------------------
  # Test 4: Sparkline with recent visitors produces daily D1 rates
  # --------------------------------------------------------------------------
  test 'summary sparkline has entries when recent visitors exist' do
    # Insert 2 visitors with first_seen = now-5d
    # v100: returns on day+1 (now-4d) -> retained D1
    # v101: does NOT return on day+1 -> not retained D1
    pid = @project.id
    now = Time.current

    insert_ch_user_profiles([
      retention_profile(pid, 2100, 'ios', 'US', now - 5.days, now - 4.days),
      retention_profile(pid, 2101, 'ios', 'US', now - 5.days, now - 5.days)
    ])
    insert_ch_visitor_daily([
      retention_vd(pid, 2100, 'ios', now - 5.days),
      retention_vd(pid, 2100, 'ios', now - 4.days),
      retention_vd(pid, 2101, 'ios', now - 5.days)
    ])

    result = Analytics::RetentionService.summary(@project.id)

    # There should be a sparkline entry for (now-5d).to_date
    sparkline_dates = result[:sparkline].map { |s| s[:date] }
    target_date = (now - 5.days).to_date.to_s
    assert_includes sparkline_dates, target_date,
                    "Sparkline should include the date #{target_date}"

    entry = result[:sparkline].find { |s| s[:date] == target_date }
    # 2 users, 1 retained on day+1 => 50.0%
    assert_equal 50.0, entry[:rate], "1 of 2 retained on day+1 = 50%%"
  end

  # ==========================================================================
  # Platform isolation test
  # ==========================================================================

  # --------------------------------------------------------------------------
  # Test 8: Platform filter isolates ios-only retention
  # --------------------------------------------------------------------------
  #
  # The platform filter scopes BOTH the numerator (visitor_max / visitor_daily)
  # AND the denominator (up / user_profiles, which carries a platform column). So
  # the denominator is the 8 iOS-profile visitors — the android-only (v2) and
  # web-only (v5) installs are excluded from both sides.
  #
  # visitor_max CTE with platform='ios' (only ios visitor_daily rows):
  #   v1: max = now-1d, v3: now-5d, v4: now-35d, v6: now-34d, v7: now-28d,
  #   v8: now-28d, v9: now-5d, v10: now-28d ; v2/v5 not iOS → excluded.
  #
  # Denominator = 8 iOS-profile visitors (v1,v3,v4,v6,v7,v8,v9,v10).
  #
  # D1 retained (max_event_date >= now-34d):
  #     v1, v3, v6, v7, v8, v9, v10 = 7 ; v4(now-35 no) → 7/8 = 87.5%
  # D7 retained (max >= now-28d):
  #     v1, v3, v7, v8, v9, v10 = 6 ; v4/v6 no → 6/8 = 75.0%
  # D30 retained (max >= now-5d):
  #     v1, v3, v9 = 3 → 3/8 = 37.5%
  test 'summary with ios platform filter returns ios-only rates' do
    result = Analytics::RetentionService.summary(@project.id, platform: 'ios')

    assert_equal 87.5, result[:day_1],  "iOS D1: 7 of 8 iOS installs retained"
    assert_equal 75.0, result[:day_7],  "iOS D7: 6 of 8 iOS installs retained"
    assert_equal 37.5, result[:day_30], "iOS D30: 3 of 8 iOS installs retained"
  end

  # ==========================================================================
  # Date range filtering tests
  # ==========================================================================

  # --------------------------------------------------------------------------
  # Test 13: Summary with date range excludes out-of-range visitors
  # --------------------------------------------------------------------------
  #
  # Add 2 visitors with first_seen = now-10d:
  #   v20 (ios, US): active days -10, -9, -3 -> D1 retained, D7 retained
  #   v21 (ios, DE): active days -10 only (churned) -> D1 NOT retained
  #
  # Date range [now-15d, now-1d]:
  #   Original 10 visitors (first_seen=now-35d) are EXCLUDED (outside range).
  #   Only v20 and v21 are in range.
  #   D1 eligible: 2 (both first_seen=now-10d <= now-1d). retained: v20 (1 of 2) = 50.0%
  #   D7 eligible: 2 (first_seen=now-10d <= now-7d). retained: v20 (max=-3d >= -3d) = 50.0%
  test 'summary with date range excludes out of range visitors' do
    insert_date_range_visitors

    start_date = (Time.current - 15.days).to_date
    end_date   = (Time.current - 1.day).to_date

    result = Analytics::RetentionService.summary(
      @project.id,
      start_date: start_date,
      end_date: end_date
    )

    assert_equal 50.0, result[:day_1],  "Date-range D1: 1 of 2 recent visitors retained"
    assert_equal 50.0, result[:day_7],  "Date-range D7: 1 of 2 recent visitors retained"
  end

  # --------------------------------------------------------------------------
  # Test 14: Summary with date range restricts sparkline to that range
  # --------------------------------------------------------------------------
  test 'summary sparkline respects date range' do
    insert_date_range_visitors

    start_date = (Time.current - 15.days).to_date
    end_date   = (Time.current - 1.day).to_date

    result = Analytics::RetentionService.summary(
      @project.id,
      start_date: start_date,
      end_date: end_date
    )

    sparkline_dates = result[:sparkline].map { |s| s[:date] }
    target_date = (Time.current - 10.days).to_date.to_s

    assert_includes sparkline_dates, target_date,
                    "Sparkline should include the recent cohort date"

    # Original visitors at now-35d should NOT appear in sparkline
    old_date = (Time.current - 35.days).to_date.to_s
    refute_includes sparkline_dates, old_date,
                    "Sparkline should exclude dates outside the range"
  end

  # ==========================================================================
  # Filter narrowing tests
  # ==========================================================================

  # --------------------------------------------------------------------------
  # Test 16: Summary with country filter narrows to matching visitors
  # --------------------------------------------------------------------------
  #
  # Insert session_events with country='US' for v1, v3, v4.
  # Filter: country is US.
  # The filtered_visitors CTE selects visitors who have session_events with country=US.
  #   v1: has US session_event -> included, D1 retained (max=-1d)
  #   v3: has US session_event -> included, D1 retained (max=-5d)
  #   v4: has US session_event -> included, D1 NOT retained (max=-35d)
  # Denominator: all 10 visitors, but INNER JOIN with filtered_visitors -> only 3.
  #   D1: 2 of 3 = 66.7%
  #   D7: v1(max=-1 yes), v3(max=-5 yes) = 2 of 3 = 66.7%
  #   D30: v1(max=-1 yes), v3(max=-5 yes) = 2 of 3 = 66.7%
  test 'summary with country filter narrows to matching visitors' do
    insert_filter_session_events

    filters = [{ 'field' => 'country', 'operator' => 'is', 'value' => 'US' }]
    result = Analytics::RetentionService.summary(@project.id, filters: filters)

    assert_equal 66.7, result[:day_1],  "Filtered D1: 2 of 3 US visitors retained"
    assert_equal 66.7, result[:day_7],  "Filtered D7: 2 of 3 US visitors retained"
    assert_equal 66.7, result[:day_30], "Filtered D30: 2 of 3 US visitors retained"
  end

  # --------------------------------------------------------------------------
  # Test 19: Filter with disallowed field is silently ignored
  # --------------------------------------------------------------------------
  test 'filter with disallowed field is ignored and returns unfiltered results' do
    insert_filter_session_events

    # 'bogus_field' is not in RETENTION_FILTER_FIELDS -> silently dropped
    filters = [{ 'field' => 'bogus_field', 'operator' => 'is', 'value' => 'anything' }]
    result = Analytics::RetentionService.summary(@project.id, filters: filters)

    # Should return same as unfiltered (D1=90.0, D7=80.0, D30=50.0)
    assert_equal 90.0, result[:day_1],  "Bogus filter ignored: D1 same as unfiltered"
    assert_equal 80.0, result[:day_7],  "Bogus filter ignored: D7 same as unfiltered"
    assert_equal 50.0, result[:day_30], "Bogus filter ignored: D30 same as unfiltered"
  end

  # --------------------------------------------------------------------------
  # Test 20: Empty filters array returns unfiltered results
  # --------------------------------------------------------------------------
  test 'empty filters array returns unfiltered results' do
    result = Analytics::RetentionService.summary(@project.id, filters: [])

    assert_equal 90.0, result[:day_1]
    assert_equal 80.0, result[:day_7]
    assert_equal 50.0, result[:day_30]
  end

  # --------------------------------------------------------------------------
  # Test 21: Visitor ID filter narrows to single visitor
  # --------------------------------------------------------------------------
  test 'visitor_id filter narrows to single visitor' do
    insert_filter_session_events

    # Filter to v1 only (fully retained: D1, D7, D30)
    filters = [{ 'field' => 'visitor_id', 'operator' => 'is', 'value' => golden_visitor(1) }]
    result = Analytics::RetentionService.summary(@project.id, filters: filters)

    assert_equal 100.0, result[:day_1],  "Single retained visitor: D1 = 100%%"
    assert_equal 100.0, result[:day_7],  "Single retained visitor: D7 = 100%%"
    assert_equal 100.0, result[:day_30], "Single retained visitor: D30 = 100%%"
  end

  # ==========================================================================
  # Unit tests — visitor_filter_cte and cohort_date_filter
  # ==========================================================================

  # --------------------------------------------------------------------------
  # Test 22: visitor_filter_cte returns empty strings for empty filters
  # --------------------------------------------------------------------------
  test 'visitor_filter_cte returns empty for nil and empty filters' do
    cte, join = Analytics::RetentionService.send(:visitor_filter_cte, @project.id, [])
    assert_equal '', cte
    assert_equal '', join

    cte2, join2 = Analytics::RetentionService.send(:visitor_filter_cte, @project.id, nil)
    assert_equal '', cte2
    assert_equal '', join2
  end

  # --------------------------------------------------------------------------
  # Test 23: visitor_filter_cte generates CTE for valid filters
  # --------------------------------------------------------------------------
  test 'visitor_filter_cte generates SQL for valid filters' do
    filters = [{ 'field' => 'country', 'operator' => 'is', 'value' => 'US' }]
    cte, join = Analytics::RetentionService.send(:visitor_filter_cte, @project.id, filters)

    assert_match(/filtered_visitors/, cte, "CTE should contain filtered_visitors")
    assert_match(/se\.country = 'US'/, cte, "CTE should filter on country")
    assert_match(/INNER JOIN filtered_visitors/, join, "Join should be INNER JOIN")
    assert_match(/up\.visitor_id/, join, "Default join table should be 'up'")
  end

  # --------------------------------------------------------------------------
  # Test 24: visitor_filter_cte respects join_table parameter
  # --------------------------------------------------------------------------
  test 'visitor_filter_cte uses custom join table' do
    filters = [{ 'field' => 'country', 'operator' => 'is', 'value' => 'US' }]
    _, join = Analytics::RetentionService.send(:visitor_filter_cte, @project.id, filters, join_table: 'se')

    assert_match(/se\.visitor_id/, join, "Join should reference custom table alias 'se'")
    refute_match(/up\.visitor_id/, join, "Join should NOT reference default table 'up'")
  end

  # --------------------------------------------------------------------------
  # Test 25: visitor_filter_cte ignores disallowed fields
  # --------------------------------------------------------------------------
  test 'visitor_filter_cte ignores disallowed fields' do
    filters = [{ 'field' => 'evil_field', 'operator' => 'is', 'value' => 'injection' }]
    cte, join = Analytics::RetentionService.send(:visitor_filter_cte, @project.id, filters)

    assert_equal '', cte, "Disallowed field should produce empty CTE"
    assert_equal '', join, "Disallowed field should produce empty join"
  end

  # --------------------------------------------------------------------------
  # Test 26: cohort_date_filter returns empty string for nil dates
  # --------------------------------------------------------------------------
  test 'cohort_date_filter returns empty for nil dates' do
    result = Analytics::RetentionService.send(:cohort_date_filter, nil, nil)
    assert_equal '', result
  end

  # --------------------------------------------------------------------------
  # Test 27: cohort_date_filter with start_date only
  # --------------------------------------------------------------------------
  test 'cohort_date_filter with start date only' do
    result = Analytics::RetentionService.send(:cohort_date_filter, Date.new(2026, 3, 1), nil)

    assert_match(/first_seen.*>=.*2026-03-01/, result)
    refute_match(/<=/, result, "Should not have end date clause")
  end

  # --------------------------------------------------------------------------
  # Test 28: cohort_date_filter with end_date only
  # --------------------------------------------------------------------------
  test 'cohort_date_filter with end date only' do
    result = Analytics::RetentionService.send(:cohort_date_filter, nil, Date.new(2026, 5, 1))

    assert_match(/first_seen.*<=.*2026-05-01/, result)
    refute_match(/>=/, result, "Should not have start date clause")
  end

  # --------------------------------------------------------------------------
  # Test 29: cohort_date_filter with both dates
  # --------------------------------------------------------------------------
  test 'cohort_date_filter with both dates' do
    result = Analytics::RetentionService.send(
      :cohort_date_filter, Date.new(2026, 3, 1), Date.new(2026, 5, 1)
    )

    assert_match(/first_seen.*>=.*2026-03-01/, result)
    assert_match(/first_seen.*<=.*2026-05-01/, result)
    assert result.start_with?(' AND '), "Should start with AND"
  end

  # ==========================================================================
  # Edge case tests
  # ==========================================================================

  # --------------------------------------------------------------------------
  # Test 11: Empty project returns nil rates and empty arrays
  # --------------------------------------------------------------------------
  test 'summary returns nil rates for project with no data' do
    # Use a project ID that has no CH data (decoy project after its data is cleared)
    empty_pid = 999_999_999
    result = Analytics::RetentionService.summary(empty_pid)

    assert_nil result[:day_1]
    assert_nil result[:day_7]
    assert_nil result[:day_30]
    assert_equal [], result[:sparkline]
    assert_nil result[:median_churn_day]
  end

  # --------------------------------------------------------------------------
  # Test 12: Decoy project data does not leak into golden project results
  # --------------------------------------------------------------------------
  test 'retention excludes decoy project data' do
    # The decoy visitor (dv1) has perfect retention (D1/D7/D30 all retained).
    # If it leaked into P1, rates would change.
    # With 10 P1 visitors: D1=90.0. If decoy leaked: 10 retained out of 11 = 90.9.
    result = Analytics::RetentionService.summary(@project.id)

    assert_equal 90.0, result[:day_1], "D1 should be exactly 90.0%%, not affected by decoy"
  end

  private

  # ==========================================================================
  # Retention-specific data insertion
  # ==========================================================================
  # Uses Time.current-relative timestamps so CH `now()` eligibility works.

  def insert_retention_golden_data
    pid = @project.id
    dpid = @decoy_project.id
    now = Time.current

    insert_retention_profiles(pid, now)
    insert_retention_visitor_daily(pid, now)
    insert_retention_session_events(pid, now)
    insert_decoy_retention_data(dpid, now)
  end

  # ---------------------------------------------------------------------------
  # User profiles: 10 golden visitors + 1 decoy
  # ---------------------------------------------------------------------------
  # All golden visitors: first_seen = now-35d, last_seen varies.
  def insert_retention_profiles(pid, now)
    profiles = [
      # Core visitors
      retention_profile(pid, golden_visitor(1), 'ios',     'US', now - 35.days, now - 1.day),
      retention_profile(pid, golden_visitor(2), 'android', 'DE', now - 35.days, now - 1.day),
      retention_profile(pid, golden_visitor(3), 'ios',     'US', now - 35.days, now - 5.days),
      retention_profile(pid, golden_visitor(4), 'ios',     'US', now - 35.days, now - 35.days),
      retention_profile(pid, golden_visitor(5), 'web',     'GB', now - 35.days, now - 1.day),

      # Extra visitors (v6-v10) to pad retention-rate denominators
      retention_profile(pid, golden_visitor(6),  'ios', 'US', now - 35.days, now - 34.days),
      retention_profile(pid, golden_visitor(7),  'ios', 'US', now - 35.days, now - 28.days),
      retention_profile(pid, golden_visitor(8),  'ios', 'US', now - 35.days, now - 28.days),
      retention_profile(pid, golden_visitor(9),  'ios', 'US', now - 35.days, now - 5.days),
      retention_profile(pid, golden_visitor(10), 'ios', 'US', now - 35.days, now - 28.days)
    ]

    insert_ch_user_profiles(profiles)
  end

  # ---------------------------------------------------------------------------
  # Visitor daily rows: one per visitor per active day
  # ---------------------------------------------------------------------------
  def insert_retention_visitor_daily(pid, now)
    rows = [
      # v1 (ios): active days -35, -34, -28, -5, -1
      retention_vd(pid, golden_visitor(1), 'ios',     now - 35.days),
      retention_vd(pid, golden_visitor(1), 'ios',     now - 34.days),
      retention_vd(pid, golden_visitor(1), 'ios',     now - 28.days),
      retention_vd(pid, golden_visitor(1), 'ios',     now - 5.days),
      retention_vd(pid, golden_visitor(1), 'ios',     now - 1.day),

      # v2 (android): active days -35, -34, -28, -1
      retention_vd(pid, golden_visitor(2), 'android', now - 35.days),
      retention_vd(pid, golden_visitor(2), 'android', now - 34.days),
      retention_vd(pid, golden_visitor(2), 'android', now - 28.days),
      retention_vd(pid, golden_visitor(2), 'android', now - 1.day),

      # v3 (ios): active days -35, -34, -28, -5
      retention_vd(pid, golden_visitor(3), 'ios',     now - 35.days),
      retention_vd(pid, golden_visitor(3), 'ios',     now - 34.days),
      retention_vd(pid, golden_visitor(3), 'ios',     now - 28.days),
      retention_vd(pid, golden_visitor(3), 'ios',     now - 5.days),

      # v4 (ios): active day -35 only (churned)
      retention_vd(pid, golden_visitor(4), 'ios',     now - 35.days),

      # v5 (web): active days -35, -34, -1
      retention_vd(pid, golden_visitor(5), 'web',     now - 35.days),
      retention_vd(pid, golden_visitor(5), 'web',     now - 34.days),
      retention_vd(pid, golden_visitor(5), 'web',     now - 1.day),

      # v6 (ios): active days -35, -34
      retention_vd(pid, golden_visitor(6), 'ios',     now - 35.days),
      retention_vd(pid, golden_visitor(6), 'ios',     now - 34.days),

      # v7 (ios): active days -35, -34, -28
      retention_vd(pid, golden_visitor(7), 'ios',     now - 35.days),
      retention_vd(pid, golden_visitor(7), 'ios',     now - 34.days),
      retention_vd(pid, golden_visitor(7), 'ios',     now - 28.days),

      # v8 (ios): active days -35, -28
      retention_vd(pid, golden_visitor(8), 'ios',     now - 35.days),
      retention_vd(pid, golden_visitor(8), 'ios',     now - 28.days),

      # v9 (ios): active days -35, -34, -28, -5
      retention_vd(pid, golden_visitor(9), 'ios',     now - 35.days),
      retention_vd(pid, golden_visitor(9), 'ios',     now - 34.days),
      retention_vd(pid, golden_visitor(9), 'ios',     now - 28.days),
      retention_vd(pid, golden_visitor(9), 'ios',     now - 5.days),

      # v10 (ios): active days -35, -34, -28
      retention_vd(pid, golden_visitor(10), 'ios',    now - 35.days),
      retention_vd(pid, golden_visitor(10), 'ios',    now - 34.days),
      retention_vd(pid, golden_visitor(10), 'ios',    now - 28.days)
    ]

    insert_ch_visitor_daily(rows)
  end

  # ---------------------------------------------------------------------------
  # Session events: screens seen on first_seen date (for filter-CTE tests)
  # ---------------------------------------------------------------------------
  def insert_retention_session_events(pid, now)
    first_day = now - 35.days
    rows = [
      # HomeScreen on first_seen date: v1, v2, v3, v4, v6, v7, v8, v9
      retention_se(pid, 'ret_sess_v1', golden_visitor(1),  1,  'OPEN', 'HomeScreen',     'ios',     first_day + 1.minute),
      retention_se(pid, 'ret_sess_v2', golden_visitor(2),  2,  'OPEN', 'HomeScreen',     'android', first_day + 2.minutes),
      retention_se(pid, 'ret_sess_v3', golden_visitor(3),  3,  'OPEN', 'HomeScreen',     'ios',     first_day + 3.minutes),
      retention_se(pid, 'ret_sess_v4', golden_visitor(4),  4,  'OPEN', 'HomeScreen',     'ios',     first_day + 4.minutes),
      retention_se(pid, 'ret_sess_v6', golden_visitor(6),  6,  'OPEN', 'HomeScreen',     'ios',     first_day + 6.minutes),
      retention_se(pid, 'ret_sess_v7', golden_visitor(7),  7,  'OPEN', 'HomeScreen',     'ios',     first_day + 7.minutes),
      retention_se(pid, 'ret_sess_v8', golden_visitor(8),  8,  'OPEN', 'HomeScreen',     'ios',     first_day + 8.minutes),
      retention_se(pid, 'ret_sess_v9', golden_visitor(9),  9,  'OPEN', 'HomeScreen',     'ios',     first_day + 9.minutes),

      # SettingsScreen on first_seen date: v9, v10
      retention_se(pid, 'ret_sess_v9', golden_visitor(9),  10, 'OPEN', 'SettingsScreen', 'ios',     first_day + 10.minutes),
      retention_se(pid, 'ret_sess_v10', golden_visitor(10), 11, 'OPEN', 'SettingsScreen', 'ios',     first_day + 11.minutes)
    ]

    insert_ch_session_events(rows)
  end

  # ---------------------------------------------------------------------------
  # Decoy data: 1 visitor with perfect retention in decoy project
  # ---------------------------------------------------------------------------
  def insert_decoy_retention_data(dpid, now)
    dv = decoy_visitor(1)

    insert_ch_user_profiles([
      retention_profile(dpid, dv, 'ios', 'JP', now - 35.days, now - 1.day)
    ])

    insert_ch_visitor_daily([
      retention_vd(dpid, dv, 'ios', now - 35.days),
      retention_vd(dpid, dv, 'ios', now - 34.days),
      retention_vd(dpid, dv, 'ios', now - 28.days),
      retention_vd(dpid, dv, 'ios', now - 5.days),
      retention_vd(dpid, dv, 'ios', now - 1.day)
    ])
  end

  # ==========================================================================
  # Row builder helpers (Time.current-relative, not FROZEN_TIME)
  # ==========================================================================

  def retention_profile(pid, visitor_id, platform, country, first_seen, last_seen)
    {
      project_id:     pid,
      visitor_id:     visitor_id,
      sdk_identifier: '',
      first_seen:     first_seen.utc.strftime(Analytics::QueryHelpers::CH_DATETIME_FMT),
      last_seen:      last_seen.utc.strftime(Analytics::QueryHelpers::CH_DATETIME_FMT),
      country:        country,
      platform:       platform,
      inviter_id:     0
    }
  end

  def retention_vd(pid, visitor_id, platform, time)
    {
      project_id:            pid,
      visitor_id:            visitor_id,
      event_date:            time.to_date.to_s,
      event_type:            'OPEN',
      platform:              platform,
      cnt:                   1,
      total_engagement_time: 0,
      inviter_id_state:      0
    }
  end

  def retention_se(pid, session_id, visitor_id, evt_n, event_type, screen_name, platform, time,
                   country: '')
    {
      project_id:      pid,
      session_id:      session_id,
      visitor_id:      visitor_id,
      device_id:       visitor_id,
      event_id:        "retention_evt_#{evt_n}",
      event_date:      time.to_date.to_s,
      event_type:      event_type,
      event_name:      '',
      screen_name:     screen_name,
      platform:        platform,
      app_version:     '',
      country:         country,
      device_model:    '',
      link_id:         0,
      campaign_id:     0,
      tracking_source: '',
      engagement_time: 0,
      created_at:      time.utc.strftime(Analytics::QueryHelpers::CH_DATETIME_FMT)
    }
  end

  # ==========================================================================
  # Additional data insertion for date-range and filter tests
  # ==========================================================================

  # Insert 2 visitors with first_seen = now-10d for date-range exclusion tests.
  # v20: active days -10, -9, -3 (retained D1, D7)
  # v21: active day -10 only (churned)
  def insert_date_range_visitors
    pid = @project.id
    now = Time.current

    insert_ch_user_profiles([
      retention_profile(pid, golden_visitor(20), 'ios', 'US', now - 10.days, now - 3.days),
      retention_profile(pid, golden_visitor(21), 'ios', 'DE', now - 10.days, now - 10.days)
    ])

    insert_ch_visitor_daily([
      retention_vd(pid, golden_visitor(20), 'ios', now - 10.days),
      retention_vd(pid, golden_visitor(20), 'ios', now - 9.days),
      retention_vd(pid, golden_visitor(20), 'ios', now - 3.days),
      retention_vd(pid, golden_visitor(21), 'ios', now - 10.days)
    ])
  end

  # Insert session_events with country='US' for v1, v3, v4 to test filter CTE.
  # These are additional SEs (won't conflict with existing HomeScreen SEs which
  # have country='' — the filter CTE just needs any matching row).
  def insert_filter_session_events
    pid = @project.id
    now = Time.current
    first_day = now - 35.days

    insert_ch_session_events([
      retention_se(pid, 'filt_v1', golden_visitor(1), 100, 'OPEN', 'FilterScreen', 'ios', first_day + 20.minutes, country: 'US'),
      retention_se(pid, 'filt_v3', golden_visitor(3), 101, 'OPEN', 'FilterScreen', 'ios', first_day + 21.minutes, country: 'US'),
      retention_se(pid, 'filt_v4', golden_visitor(4), 102, 'OPEN', 'FilterScreen', 'ios', first_day + 22.minutes, country: 'US')
    ])
  end
end
