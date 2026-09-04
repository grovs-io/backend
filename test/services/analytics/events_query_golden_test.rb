# frozen_string_literal: true

require 'test_helper'

# Golden dataset tests for Analytics::EventsQueryService. Every test queries the
# shared base dataset (27 P1 events + 5 P2 decoy events) and asserts exact
# values, not just shapes. Decoy isolation is verified in every test that
# returns row-level data.
#
# The base dataset is defined in GoldenDatasetHelper and documented in
# docs/plans/2026-05-11-clickhouse-golden-tests-design.md section 2.
#
# Date range: golden_start_date (2026-04-24) .. golden_end_date (2026-04-30)
# FROZEN_TIME: 2026-05-01 12:00:00 UTC
class Analytics::EventsQueryGoldenTest < ActiveSupport::TestCase
  include ClickhouseTestHelper
  include GoldenDatasetHelper

  fixtures :projects, :instances

  setup do
    skip_unless_clickhouse!
    setup_golden_dataset
  end

  teardown { teardown_golden_dataset }

  # --------------------------------------------------------------------------
  # 1. test_list_returns_exact_events_in_date_range
  #    Query the full 7-day range. Assert 27 events, 0 decoy events, and
  #    correct event_type/visitor_id for each.
  # --------------------------------------------------------------------------
  test 'list returns exact events in date range' do
    result = Analytics::EventsQueryService.list(
      golden_project_id,
      start_date: golden_start_date,
      end_date:   golden_end_date,
      limit:      200
    )

    data = result[:data]
    assert_equal 27, data.size, "Expected exactly 27 golden events, got #{data.size}"

    # Verify every golden event is present
    expected_ids = (1..27).map { |n| "golden_evt_#{n}" }.sort
    actual_ids   = data.map { |row| row['event_id'] }.sort
    assert_equal expected_ids, actual_ids

    # Decoy isolation
    assert_no_decoy_visitors(data)
    assert_no_decoy_events(data)
    assert_no_decoy_project(data)
  end

  # --------------------------------------------------------------------------
  # 2. test_list_default_sort_order
  #    Default sort is created_at DESC. First event should be from day -1,
  #    last event from day -7.
  # --------------------------------------------------------------------------
  test 'list default sort order is created_at desc' do
    result = Analytics::EventsQueryService.list(
      golden_project_id,
      start_date: golden_start_date,
      end_date:   golden_end_date,
      limit:      200
    )

    data = result[:data]
    timestamps = data.map { |row| row['created_at'].to_s }

    # Verify descending order
    assert_equal timestamps.sort.reverse, timestamps,
                 'Events should be sorted by created_at DESC'

    # First event should be from day -1 (Apr 30) -- the latest in range
    first_ts = data.first['created_at'].to_s
    assert first_ts.start_with?('2026-04-30'), "Expected first event on 2026-04-30, got #{first_ts}"

    # Last event should be from day -7 (Apr 24) -- the earliest in range
    last_ts = data.last['created_at'].to_s
    assert last_ts.start_with?('2026-04-24'), "Expected last event on 2026-04-24, got #{last_ts}"
  end

  # --------------------------------------------------------------------------
  # 3. test_volume_buckets_match_hand_count
  #    bucket: 'day'. Hand-counted from the golden dataset table:
  #      Day -7 (Apr 24): v1 events 1-4                     = 4
  #      Day -6 (Apr 25): v4 events 20-23                   = 4
  #      Day -5 (Apr 26): v2 events 8-11                    = 4
  #      Day -4 (Apr 27): v3 events 15-17                   = 3
  #      Day -3 (Apr 28): v1 events 5-6, v5 events 24-26   = 5
  #      Day -2 (Apr 29): v2 events 12-14                   = 3
  #      Day -1 (Apr 30): v1 event 7, v3 events 18-19, v5 27 = 4
  #    Total: 27
  # --------------------------------------------------------------------------
  test 'volume day buckets match hand counted data' do
    result = Analytics::EventsQueryService.volume(
      golden_project_id,
      start_date: golden_start_date,
      end_date:   golden_end_date,
      bucket:     'day'
    )

    counts = result[:buckets].to_h { |row| [row['bucket'].to_s, row['count'].to_i] }

    expected = {
      '2026-04-24' => 4,
      '2026-04-25' => 4,
      '2026-04-26' => 4,
      '2026-04-27' => 3,
      '2026-04-28' => 5,
      '2026-04-29' => 3,
      '2026-04-30' => 4
    }

    assert_equal expected, counts
    assert_equal 27, counts.values.sum
  end

  # --------------------------------------------------------------------------
  # 4. test_filter_by_platform_ios
  #    v1: ios, 7 events (1-7). v4: ios, 4 events (20-23). Total ios = 11.
  # --------------------------------------------------------------------------
  test 'filter by platform ios returns exactly 11 events' do
    result = Analytics::EventsQueryService.list(
      golden_project_id,
      start_date: golden_start_date,
      end_date:   golden_end_date,
      limit:      200,
      filters:    [{ 'field' => 'platform', 'operator' => 'is', 'value' => 'ios' }]
    )

    data = result[:data]
    assert_equal 11, data.size, "Expected exactly 11 ios events"
    assert data.all? { |row| row['platform'] == 'ios' }, 'All results must be ios'

    # Verify correct visitor breakdown: v1 (1001) has 7, v4 (1004) has 4
    visitor_counts = data.group_by { |row| row['visitor_id'] }.transform_values(&:size)
    assert_equal({ golden_visitor(1) => 7, golden_visitor(4) => 4 }, visitor_counts)

    assert_no_decoy_visitors(data)
  end

  # --------------------------------------------------------------------------
  # 5. test_filter_by_country
  #    v2: DE, 7 events (8-14). Only v2 is in DE.
  # --------------------------------------------------------------------------
  test 'filter by country DE returns exactly 7 events' do
    result = Analytics::EventsQueryService.list(
      golden_project_id,
      start_date: golden_start_date,
      end_date:   golden_end_date,
      limit:      200,
      filters:    [{ 'field' => 'country', 'operator' => 'is', 'value' => 'DE' }]
    )

    data = result[:data]
    assert_equal 7, data.size, "Expected exactly 7 DE events"
    assert data.all? { |row| row['country'] == 'DE' }, 'All results must be DE'
    assert_equal [golden_visitor(2)], data.map { |row| row['visitor_id'] }.uniq,
                 'Only v2 should appear in DE results'
  end

  # --------------------------------------------------------------------------
  # 6. test_field_values_platform
  #    Golden data has: ios (v1, v4), android (v2), web (v3), desktop (v5).
  #    desktop collapses to web at read time: ['android', 'ios', 'web']
  # --------------------------------------------------------------------------
  test 'field values returns exact sorted platform list' do
    result = Analytics::EventsQueryService.field_values(
      golden_project_id,
      field: 'platform',
      limit: 20,
      start_date: golden_start_date,
      end_date: golden_end_date
    )

    assert_equal %w[android ios web], result[:values]
  end

  # --------------------------------------------------------------------------
  # 7. test_total_count_exact
  #    include_count: true. total_count must equal 27.
  # --------------------------------------------------------------------------
  test 'total count is exactly 27 with include count true' do
    result = Analytics::EventsQueryService.list(
      golden_project_id,
      start_date:    golden_start_date,
      end_date:      golden_end_date,
      limit:         10,
      include_count: true
    )

    assert_equal 10, result[:data].size, 'Page should have 10 events'
    assert_equal 27, result[:total_count], 'Total count across all pages must be 27'
  end

  # --------------------------------------------------------------------------
  # 8. test_every_result_excludes_decoy_project
  #    Run the list query and verify all decoy assertion helpers pass.
  # --------------------------------------------------------------------------
  test 'every result excludes decoy project data' do
    result = Analytics::EventsQueryService.list(
      golden_project_id,
      start_date: golden_start_date,
      end_date:   golden_end_date,
      limit:      200
    )

    data = result[:data]
    assert_equal 27, data.size

    assert_no_decoy_visitors(data)
    assert_no_decoy_events(data)
    assert_no_decoy_project(data)

    # Also verify volume doesn't leak decoy data
    vol = Analytics::EventsQueryService.volume(
      golden_project_id,
      start_date: golden_start_date,
      end_date:   golden_end_date,
      bucket:     'day'
    )
    total = vol[:buckets].sum { |b| b['count'].to_i }
    assert_equal 27, total, 'Volume total must not include decoy events'
  end

  # --------------------------------------------------------------------------
  # 9. test_date_range_boundary_exclusion
  #    Insert an event at -8 days (outside the 7-day range). Query -7d to -1d.
  #    Assert it is NOT in results. Total must still be 27.
  # --------------------------------------------------------------------------
  test 'date range boundary excludes event outside range' do
    # Insert an event at -8d (Apr 23), outside golden_start_date (Apr 24)
    out_of_range = evt(
      golden_project_id, 99, 'OPEN', 'OutOfRange', golden_visitor(1),
      'ios', '2.0', 'US', 'sess_oob', -8.days
    )
    insert_ch_events([out_of_range])

    result = Analytics::EventsQueryService.list(
      golden_project_id,
      start_date:    golden_start_date,
      end_date:      golden_end_date,
      limit:         200,
      include_count: true
    )

    assert_equal 27, result[:data].size, 'Out-of-range event must not appear'
    assert_equal 27, result[:total_count]
    refute result[:data].any? { |row| row['event_id'] == 'golden_evt_99' },
           'Event 99 (outside range) must not appear in results'
  end

  # --------------------------------------------------------------------------
  # 10. test_cursor_pagination_page_2
  #     Paginate 27 events with limit=10. Three pages: 10, 10, 7.
  #     No overlap. Union = 27.
  # --------------------------------------------------------------------------
  test 'cursor pagination has no overlap and covers all 27 events' do
    page1 = Analytics::EventsQueryService.list(
      golden_project_id,
      start_date: golden_start_date,
      end_date:   golden_end_date,
      limit:      10
    )
    assert_equal 10, page1[:data].size
    assert_not_nil page1[:next_cursor], 'Page 1 must have a next cursor'

    page2 = Analytics::EventsQueryService.list(
      golden_project_id,
      start_date: golden_start_date,
      end_date:   golden_end_date,
      limit:      10,
      cursor:     page1[:next_cursor]
    )
    assert_equal 10, page2[:data].size
    assert_not_nil page2[:next_cursor], 'Page 2 must have a next cursor'

    page3 = Analytics::EventsQueryService.list(
      golden_project_id,
      start_date: golden_start_date,
      end_date:   golden_end_date,
      limit:      10,
      cursor:     page2[:next_cursor]
    )
    assert_equal 7, page3[:data].size, 'Page 3 should have remaining 7 events'
    assert_nil page3[:next_cursor], 'Page 3 should not have a next cursor'

    # Verify no overlap and full coverage
    all_ids = [page1, page2, page3].flat_map { |p| p[:data].map { |row| row['event_id'] } }
    assert_equal all_ids.uniq.sort, all_ids.sort, 'No duplicate event_ids across pages'
    assert_equal 27, all_ids.size, 'Union of all pages must be 27'
  end

  # --------------------------------------------------------------------------
  # 11. test_search_partial_match
  #     Insert an event with screen_name 'MySpecialScreen'. Search 'Special'.
  #     Assert found. Search 'Nonexistent'. Assert empty.
  # --------------------------------------------------------------------------
  test 'search partial match finds matching screen and misses nonexistent' do
    special_event = evt(
      golden_project_id, 100, 'OPEN', 'MySpecialScreen', golden_visitor(1),
      'ios', '2.0', 'US', 'sess_search', -2.days
    )
    insert_ch_events([special_event])

    # Search for 'Special' -- should find the special event
    found = Analytics::EventsQueryService.list(
      golden_project_id,
      start_date: golden_start_date,
      end_date:   golden_end_date,
      limit:      200,
      search:     'Special'
    )
    matching_ids = found[:data].map { |row| row['event_id'] }
    assert_includes matching_ids, 'golden_evt_100',
                    'Search for "Special" should find MySpecialScreen event'

    # Search for 'Nonexistent' -- should return empty
    empty = Analytics::EventsQueryService.list(
      golden_project_id,
      start_date: golden_start_date,
      end_date:   golden_end_date,
      limit:      200,
      search:     'Nonexistent'
    )
    assert_equal 0, empty[:data].size, 'Search for "Nonexistent" should return no results'
  end

  # --------------------------------------------------------------------------
  # 12. test_search_escapes_wildcards
  #     Insert event with screen_name '100%_off_sale'. Search literal '100%'.
  #     Assert only that event matches (% is escaped, not treated as wildcard).
  # --------------------------------------------------------------------------
  test 'search escapes percent wildcard correctly' do
    promo_event = evt(
      golden_project_id, 101, 'OPEN', '100%_off_sale', golden_visitor(1),
      'ios', '2.0', 'US', 'sess_promo', -2.days
    )
    insert_ch_events([promo_event])

    result = Analytics::EventsQueryService.list(
      golden_project_id,
      start_date: golden_start_date,
      end_date:   golden_end_date,
      limit:      200,
      search:     '100%'
    )

    matching_ids = result[:data].map { |row| row['event_id'] }
    assert_includes matching_ids, 'golden_evt_101',
                    'Search for "100%" should find the promo event'

    # The '%' must be escaped -- it should NOT match arbitrary strings.
    # Verify no golden base events match (none have '100%' in any searchable field).
    non_promo = result[:data].reject { |row| row['event_id'] == 'golden_evt_101' }
    assert_equal 0, non_promo.size,
                 'Escaped % should not wildcard-match unrelated events'
  end

  # --------------------------------------------------------------------------
  # 13. test_sort_by_each_column
  #     For each sortable column (created_at, event_type, event_name, platform),
  #     sort asc and verify the first result matches the expected minimum value.
  # --------------------------------------------------------------------------
  test 'sort by each supported column returns correct first value' do
    # created_at ASC: earliest event is at -7d (Apr 24 12:00 UTC)
    result_ts = Analytics::EventsQueryService.list(
      golden_project_id,
      start_date: golden_start_date,
      end_date:   golden_end_date,
      limit:      1,
      sort_by:    'created_at',
      sort_order: 'asc'
    )
    first_ts = result_ts[:data].first['created_at'].to_s
    assert first_ts.start_with?('2026-04-24'),
           "created_at ASC: first should be Apr 24, got #{first_ts}"

    # event_type ASC: alphabetically first is APP_OPEN
    result_type = Analytics::EventsQueryService.list(
      golden_project_id,
      start_date: golden_start_date,
      end_date:   golden_end_date,
      limit:      1,
      sort_by:    'event_type',
      sort_order: 'asc'
    )
    assert_equal 'APP_OPEN', result_type[:data].first['event_type'],
                 'event_type ASC: first should be APP_OPEN'

    # event_name ASC: Insert an event with a non-empty event_name so the sort
    # test is not trivially true (all base golden events have empty event_name).
    named_event = evt(
      golden_project_id, 200, 'OPEN', 'SomeScreen', golden_visitor(1),
      'ios', '2.0', 'US', 'sess_sort_test', -2.days
    )
    named_event[:event_name] = 'button_click'
    insert_ch_events([named_event])

    result_name = Analytics::EventsQueryService.list(
      golden_project_id,
      start_date: golden_start_date,
      end_date:   golden_end_date,
      limit:      50,
      sort_by:    'event_name',
      sort_order: 'asc'
    )
    # Empty strings sort before 'button_click' in ASC order
    assert_equal '', result_name[:data].first['event_name'],
                 'event_name ASC: empty strings should come first'

    # DESC: 'button_click' should come first
    result_name_desc = Analytics::EventsQueryService.list(
      golden_project_id,
      start_date: golden_start_date,
      end_date:   golden_end_date,
      limit:      1,
      sort_by:    'event_name',
      sort_order: 'desc'
    )
    assert_equal 'button_click', result_name_desc[:data].first['event_name'],
                 'event_name DESC: button_click should come first'

    # platform ASC: alphabetically first is 'android'
    result_plat = Analytics::EventsQueryService.list(
      golden_project_id,
      start_date: golden_start_date,
      end_date:   golden_end_date,
      limit:      1,
      sort_by:    'platform',
      sort_order: 'asc'
    )
    assert_equal 'android', result_plat[:data].first['platform'],
                 'platform ASC: first should be android'
  end

  # --------------------------------------------------------------------------
  # 14. test_invalid_sort_cursor_combination
  #     Test 10 covers cursor pagination with default DESC sort. This test
  #     covers ASC sort to verify cursor works in both directions.
  #     Golden dataset: 27 events, oldest on Apr 24 (golden_evt_1..4), newest
  #     on Apr 30 (golden_evt_24..27).
  # --------------------------------------------------------------------------
  test 'cursor pagination with created_at ASC covers all 27 events' do
    # ASC order: oldest events first (Apr 24 → Apr 30).
    # Event numbering does NOT follow chronological order. Chronological order:
    #   Apr 24: 1-4,  Apr 25: 20-23,  Apr 26: 8-11,  Apr 27: 15-17,
    #   Apr 28: 5-6 + 24-26,  Apr 29: 12-14,  Apr 30: 7 + 18-19 + 27
    all_events = []
    cursor = nil

    loop do
      page = Analytics::EventsQueryService.list(
        golden_project_id,
        start_date: golden_start_date,
        end_date:   golden_end_date,
        limit:      10,
        sort_by:    'created_at',
        sort_order: 'asc',
        cursor:     cursor
      )
      all_events.concat(page[:data])

      break if page[:next_cursor].nil?
      cursor = page[:next_cursor]
    end

    all_ids = all_events.map { |r| r['event_id'] }
    assert_equal 27, all_ids.size, 'ASC cursor pagination must return exactly 27 events'
    assert_equal 27, all_ids.uniq.size, 'No duplicates across ASC cursor pages'

    # Verify ASC ordering: timestamps are non-decreasing
    timestamps = all_events.map { |r| r['created_at'].to_s }
    assert_equal timestamps.sort, timestamps, 'Events must be in ASC created_at order'

    # First event must be from Apr 24 (day -7), the oldest day
    assert_includes %w[golden_evt_1 golden_evt_2 golden_evt_3 golden_evt_4],
                    all_ids.first, 'First event in ASC must be from day -7 (evt 1-4)'

    # Last event must be from Apr 30 (day -1), the newest day
    assert_includes %w[golden_evt_7 golden_evt_18 golden_evt_19 golden_evt_27],
                    all_ids.last, 'Last event in ASC must be from day -1 (evt 7/18/19/27)'
  end
end
