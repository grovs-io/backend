# frozen_string_literal: true

require 'test_helper'

# Golden dataset tests for Analytics::OverviewStatsService. Every test queries
# the shared base dataset (27 P1 events, 10 sessions, 5 visitors + P2 decoy
# data) and asserts exact values, not just shapes.
#
# The base dataset is defined in GoldenDatasetHelper and documented in
# docs/plans/2026-05-11-clickhouse-golden-tests-design.md section 2.
#
# Date range: golden_start_date (2026-04-24) .. golden_end_date (2026-04-30)
# FROZEN_TIME: 2026-05-01 12:00:00 UTC
class Analytics::OverviewGoldenTest < ActiveSupport::TestCase
  include ClickhouseTestHelper
  include GoldenDatasetHelper

  fixtures :projects, :instances

  setup do
    skip_unless_clickhouse!
    @ch_auto_rebuild_breakdowns = true
    setup_golden_dataset
  end

  teardown { teardown_golden_dataset }

  # ==========================================================================
  # OverviewStatsService tests
  # ==========================================================================

  # --------------------------------------------------------------------------
  # test_versions_exact_list
  #
  # Events table has app_version values (from golden events):
  #   v1 (7 events):  all '2.0'
  #   v2 (7 events):  4 events '1.9', 3 events '2.0'
  #   v3 (5 events):  all '' (empty → mapped to 'Unknown')
  #   v4 (4 events):  all '2.0'
  #   v5 (4 events):  all '3.0'
  #
  # Platforms: ios (2.0), android (1.9, 2.0), web (Unknown), desktop (3.0)
  # --------------------------------------------------------------------------
  test 'versions returns exact per-platform breakdown including web' do
    result = Analytics::OverviewStatsService.versions(
      golden_project_id,
      start_date: golden_start_date,
      end_date:   golden_end_date
    )

    platforms = result[:platforms]
    assert platforms.is_a?(Hash), 'platforms should be a Hash keyed by platform name'

    # ios: only version 2.0 (v1 + v4) → 2 users, 100%
    ios = platforms['ios']
    assert_equal 1, ios.size, 'ios should have 1 version (2.0)'
    assert_equal '2.0', ios[0][:version]
    assert_equal 2, ios[0][:users], 'ios 2.0: 2 visitors (v1, v4)'
    assert_equal 100.0, ios[0][:percent], 'ios 2.0: only version → 100%'

    # android: versions 1.9 (v2) and 2.0 (v2) — same visitor on both
    android = platforms['android']
    assert_equal 2, android.size, 'android should have 2 versions'
    android_map = android.to_h { |e| [e[:version], e] }
    assert_equal 1, android_map['1.9'][:users], 'android 1.9: 1 visitor (v2)'
    assert_equal 1, android_map['2.0'][:users], 'android 2.0: 1 visitor (v2)'
    assert_equal 50.0, android_map['1.9'][:percent], 'android 1.9: 1/2 = 50%'
    assert_equal 50.0, android_map['2.0'][:percent], 'android 2.0: 1/2 = 50%'

    # web: v3 has empty app_version → shows as "Unknown"
    web = platforms['web']
    assert_equal 1, web.size, 'web should have 1 version (Unknown)'
    assert_equal 'Unknown', web[0][:version], 'Empty app_version → Unknown'
    assert_equal 1, web[0][:users], 'web Unknown: 1 visitor (v3)'
    assert_equal 100.0, web[0][:percent], 'web Unknown: only version → 100%'

    # desktop: only version 3.0 (v5) → 1 user, 100%
    desktop = platforms['desktop']
    assert_equal 1, desktop.size, 'desktop should have 1 version (3.0)'
    assert_equal '3.0', desktop[0][:version]
    assert_equal 1, desktop[0][:users], 'desktop 3.0: 1 visitor (v5)'
    assert_equal 100.0, desktop[0][:percent], 'desktop 3.0: only version → 100%'
  end

  # --------------------------------------------------------------------------
  # test_user_trends_exact_daily
  #
  # A daily point counts visitors whose first activity falls in the selected
  # range and who install during that range, assigning each visitor to their
  # first-activity day.
  # --------------------------------------------------------------------------
  test 'user trends buckets new users by their first-activity day' do
    # The legacy golden fixture predates canonical lowercase event types. Seed
    # its four installs through the current event representation so the
    # first-seen rollup exercises production semantics.
    insert_ch_events([
      evt(golden_project_id, 101, 'install', '', golden_visitor(1), 'ios', '2.0', 'US', 'trend_v1', -7.days, prefix: 'trend'),
      evt(golden_project_id, 102, 'install', '', golden_visitor(4), 'ios', '2.0', 'US', 'trend_v4', -6.days, prefix: 'trend'),
      evt(golden_project_id, 103, 'install', '', golden_visitor(2), 'android', '1.9', 'DE', 'trend_v2', -5.days, prefix: 'trend'),
      evt(golden_project_id, 104, 'install', '', golden_visitor(5), 'desktop', '3.0', 'GB', 'trend_v5', -3.days, prefix: 'trend')
    ])

    result = Analytics::OverviewStatsService.user_trends(
      golden_project_id,
      start_date: golden_start_date,
      end_date:   golden_end_date
    )

    points = result[:points]
    assert points.is_a?(Array), 'points should be an array'

    points_map = points.to_h { |r| [r[:date].to_s, r[:new_users]] }

    expected = {
      '2026-04-24' => 1,
      '2026-04-25' => 1,
      '2026-04-26' => 1,
      '2026-04-27' => 0,
      '2026-04-28' => 1,
      '2026-04-29' => 0,
      '2026-04-30' => 0
    }

    expected.each do |date, expected_new_users|
      actual = points_map[date] || 0
      assert_equal expected_new_users, actual,
                   "Day #{date}: expected #{expected_new_users} new users, got #{actual}"
    end

    # Should have data for all 7 days
    assert_equal 7, points.size,
                 'Should have trend data for all 7 days in range'
  end

  # --------------------------------------------------------------------------
  # test_sources_breakdown_exact
  #
  # All 27 golden events have link_id=0/campaign_id=0, classified as 'organic'.
  # --------------------------------------------------------------------------
  test 'sources breakdown returns single organic source with exact counts' do
    result = Analytics::OverviewStatsService.sources_breakdown(
      golden_project_id,
      start_date: golden_start_date,
      end_date:   golden_end_date
    )

    sources = result[:sources]
    assert_equal 1, sources.size, 'Should have exactly 1 source (organic)'

    organic = sources.first
    assert_equal 'Organic', organic[:name]
    assert_equal 5, organic[:value],
                 'organic source should have 5 unique visitors'

    # Total is now a top-level key
    assert_equal 5, result[:total],
                 'total should equal 5 unique visitors'
  end

  # --------------------------------------------------------------------------
  # test_version_distribution_exact
  #
  # Grouped by platform + app_version (empty → "Unknown").
  # --------------------------------------------------------------------------
  test 'version distribution returns exact platform and version breakdown' do
    result = Analytics::OverviewStatsService.version_distribution(
      golden_project_id,
      start_date: golden_start_date,
      end_date:   golden_end_date
    )

    entries = result[:entries]
    assert entries.is_a?(Array), 'entries should be an array'

    # Each entry has :version, :release_date, :platforms (Hash), :total
    dist_map = {}
    entries.each do |entry|
      entry[:platforms].each do |platform, count|
        dist_map[[platform, entry[:version]]] = count
      end
    end

    assert_equal 2, dist_map[['ios', '2.0']],
                 'ios/2.0: 2 visitors (v1, v4)'
    assert_equal 1, dist_map[['android', '1.9']],
                 'android/1.9: 1 visitor (v2)'
    assert_equal 1, dist_map[['android', '2.0']],
                 'android/2.0: 1 visitor (v2)'
    assert_equal 1, dist_map[['desktop', '3.0']],
                 'desktop/3.0: 1 visitor (v5)'

    # Web: empty app_version → "Unknown"
    assert_equal 1, dist_map[['web', 'Unknown']],
                 'web/Unknown: 1 visitor (v3)'

    # Collect all versions present
    all_versions = entries.map { |e| e[:version] }
    assert_includes all_versions, '2.0'
    assert_includes all_versions, 'Unknown'
  end

  # --------------------------------------------------------------------------
  # test_sources_with_link_properties
  #
  # Insert additional events with campaign_id > 0. Verify Campaigns category
  # appears in the sources breakdown alongside Organic.
  # --------------------------------------------------------------------------
  test 'sources breakdown classifies by link properties with exact counts' do
    pid = golden_project_id

    # Insert 3 events with campaign_id=42 for 2 visitors
    campaign_events = [
      evt(pid, 50, 'OPEN', 'HomeScreen', golden_visitor(1),
          'ios', '2.0', 'US', 'sess_camp_1', -2.days).merge(campaign_id: 42, link_id: 99),
      evt(pid, 51, 'OPEN', 'SettingsScreen', golden_visitor(1),
          'ios', '2.0', 'US', 'sess_camp_1', -2.days + 1.minute).merge(campaign_id: 42, link_id: 99),
      evt(pid, 52, 'OPEN', 'HomeScreen', golden_visitor(2),
          'android', '2.0', 'DE', 'sess_camp_2', -2.days + 2.minutes).merge(campaign_id: 42, link_id: 99)
    ]
    insert_ch_events(campaign_events)

    result = Analytics::OverviewStatsService.sources_breakdown(
      golden_project_id,
      start_date: golden_start_date,
      end_date:   golden_end_date
    )

    sources = result[:sources]
    source_map = sources.to_h { |r| [r[:name], r] }

    # Organic: 5 visitors (base golden data, no link properties)
    assert_equal 5, source_map['Organic'][:value],
                 'Organic should still have 5 visitors'

    # Campaigns: 2 visitors (v1, v2 with campaign_id=42)
    assert source_map.key?('Campaigns'), 'Campaigns source should appear'
    assert_equal 2, source_map['Campaigns'][:value],
                 'Campaigns source should have 2 visitors'

    assert_equal 7, result[:total], 'Total should be 5 organic + 2 campaign visitors'
  end

  # --------------------------------------------------------------------------
  # test_every_overview_result_excludes_decoy_project
  #
  # Run all overview queries, verify no decoy data leaks.
  # Decoy project has: 5 events, version '9.0', platform 'ios', country 'JP',
  # 1 visitor (9001), 1 session ('decoy_sess_1').
  # --------------------------------------------------------------------------
  test 'every overview result excludes decoy project data' do
    # Versions should not include '9.0'
    versions = Analytics::OverviewStatsService.versions(
      golden_project_id,
      start_date: golden_start_date,
      end_date:   golden_end_date
    )
    all_versions = versions[:platforms].values.flatten.map { |e| e[:version] }
    refute_includes all_versions, '9.0',
                    'Decoy version 9.0 must not leak into versions list'

    # Sources breakdown should not include decoy events
    sources = Analytics::OverviewStatsService.sources_breakdown(
      golden_project_id,
      start_date: golden_start_date,
      end_date:   golden_end_date
    )
    assert_equal 5, sources[:total],
                 'Total visitors across all sources should be 5 (no decoy leak)'

    # Version distribution should not include '9.0'
    dist = Analytics::OverviewStatsService.version_distribution(
      golden_project_id,
      start_date: golden_start_date,
      end_date:   golden_end_date
    )
    dist_versions = dist[:entries].map { |e| e[:version] }
    refute_includes dist_versions, '9.0',
                    'Decoy version 9.0 must not appear in distribution'
  end
end
