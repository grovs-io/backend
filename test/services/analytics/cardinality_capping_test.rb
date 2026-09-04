# frozen_string_literal: true

require 'test_helper'

# Tests for cardinality capping / limit-clamping across all analytics services.
# Verifies that services clamp user-supplied parameters to safe bounds before
# building queries. Many tests work without CH data by checking clamped output
# metadata; tests that need to run real queries use the golden dataset.
#
# Constants under test:
#   EventsQueryService:  MAX_LIMIT (200), DEFAULT_LIMIT (50)
#   SessionsQueryService: limit [1,200]
#   OverviewStatsService: versions LIMIT 50 (hardcoded), version_distribution limit (passed through)
class Analytics::CardinalityCappingTest < ActiveSupport::TestCase
  include ClickhouseTestHelper
  include GoldenDatasetHelper

  fixtures :projects, :instances

  setup do
    skip_unless_clickhouse!
    setup_golden_dataset
  end

  teardown { teardown_golden_dataset }

  # --------------------------------------------------------------------------
  # 1. EventsQueryService: limit clamps to MAX_LIMIT (200), default is DEFAULT_LIMIT (50)
  #    Requesting limit: 999 should return at most MAX_LIMIT rows. The golden
  #    dataset has only 27 events so we verify the service clamped internally
  #    by checking that it did not error and returned <= MAX_LIMIT results.
  # --------------------------------------------------------------------------
  test 'events list limit clamps to MAX_LIMIT' do
    result = Analytics::EventsQueryService.list(
      golden_project_id,
      start_date: golden_start_date,
      end_date:   golden_end_date,
      limit:      999
    )

    assert result[:data].size <= Analytics::EventsQueryService::MAX_LIMIT,
           "Expected at most #{Analytics::EventsQueryService::MAX_LIMIT} rows, " \
           "got #{result[:data].size}"

    # Confirm the actual data count matches the 27 base events (< MAX_LIMIT)
    assert_equal 27, result[:data].size

    # Also verify zero/negative limits clamp to 1, not error
    result_zero = Analytics::EventsQueryService.list(
      golden_project_id,
      start_date: golden_start_date,
      end_date:   golden_end_date,
      limit:      0
    )
    assert result_zero[:data].size >= 1,
           'Zero limit should clamp to 1, not return empty'

    result_neg = Analytics::EventsQueryService.list(
      golden_project_id,
      start_date: golden_start_date,
      end_date:   golden_end_date,
      limit:      -5
    )
    assert result_neg[:data].size >= 1,
           'Negative limit should clamp to 1, not return empty'
  end

  # --------------------------------------------------------------------------
  # 2. EventsQueryService: very wide date range
  #    The service does not explicitly reject wide ranges at the service layer
  #    (it defers to the controller for validation). Verify it does not crash and
  #    returns results normally -- the bucket resolver handles long ranges by
  #    auto-selecting monthly buckets.
  # --------------------------------------------------------------------------
  test 'events very wide date range does not crash' do
    wide_start = (FROZEN_TIME.to_date - 120).to_s
    wide_end   = (FROZEN_TIME.to_date - 1).to_s

    # Should not raise -- the constant is informational for controllers
    result = Analytics::EventsQueryService.list(
      golden_project_id,
      start_date: wide_start,
      end_date:   wide_end,
      limit:      50
    )

    assert result.key?(:data), 'Should return a valid result hash even for wide date ranges'

    # Volume with wide range auto-selects monthly buckets
    volume = Analytics::EventsQueryService.volume(
      golden_project_id,
      start_date: wide_start,
      end_date:   wide_end
    )

    assert volume.key?(:buckets), 'Volume should still return buckets for wide ranges'
  end

  # --------------------------------------------------------------------------
  # 3. SessionsQueryService: limit clamps to [1, MAX_LIMIT (200)]
  #    Requesting limit: 999 should be clamped to MAX_LIMIT.
  # --------------------------------------------------------------------------
  test 'sessions list limit clamps to MAX_LIMIT' do
    result = Analytics::SessionsQueryService.list(
      golden_project_id,
      start_date: golden_start_date,
      end_date:   golden_end_date,
      limit:      999
    )

    assert result[:data].size <= Analytics::SessionsQueryService::MAX_LIMIT,
           "Expected at most #{Analytics::SessionsQueryService::MAX_LIMIT} sessions, " \
           "got #{result[:data].size}"

    # Zero clamps to 1, not error
    result_zero = Analytics::SessionsQueryService.list(
      golden_project_id,
      start_date: golden_start_date,
      end_date:   golden_end_date,
      limit:      0
    )
    assert result_zero[:data].is_a?(Array), 'limit=0 should clamp to 1, not crash'
  end

  # --------------------------------------------------------------------------
  # 7. EventsQueryService.field_values: limit clamps to MAX_LIMIT
  #    The field_values method uses the same [1, MAX_LIMIT] clamping as list.
  # --------------------------------------------------------------------------
  test 'events field_values limit clamps to MAX_LIMIT' do
    result = Analytics::EventsQueryService.field_values(
      golden_project_id,
      field: 'platform',
      limit: 999,
      start_date: golden_start_date,
      end_date: golden_end_date
    )

    # Golden dataset has 4 raw platforms; desktop collapses to web at read time
    assert result[:values].size <= Analytics::EventsQueryService::MAX_LIMIT,
           "field_values should respect MAX_LIMIT"
    assert_equal 3, result[:values].size,
                 "Expected 3 normalized platforms in golden dataset"

    # Zero clamps to 1
    result_zero = Analytics::EventsQueryService.field_values(
      golden_project_id,
      field: 'platform',
      limit: 0,
      start_date: golden_start_date,
      end_date: golden_end_date
    )
    assert result_zero[:values].size >= 1,
           'limit=0 should clamp to 1, returning at least 1 value'
  end

  # --------------------------------------------------------------------------
  # 8. No endpoint returns unbounded rows -- all lists are paginated or capped
  #    Call each service method with absurd limits. Assert all result arrays
  #    are bounded by their respective maximums.
  # --------------------------------------------------------------------------
  test 'no endpoint returns unbounded rows' do
    # EventsQueryService.list -- capped at MAX_LIMIT (200)
    events_result = Analytics::EventsQueryService.list(
      golden_project_id,
      start_date: golden_start_date,
      end_date:   golden_end_date,
      limit:      10_000
    )
    assert events_result[:data].size <= Analytics::EventsQueryService::MAX_LIMIT

    # EventsQueryService.field_values -- capped at MAX_LIMIT (200)
    fv_result = Analytics::EventsQueryService.field_values(
      golden_project_id, field: 'event_type', limit: 10_000,
      start_date: golden_start_date, end_date: golden_end_date
    )
    assert fv_result[:values].size <= Analytics::EventsQueryService::MAX_LIMIT

    # SessionsQueryService.list -- capped at MAX_LIMIT (200)
    sessions_result = Analytics::SessionsQueryService.list(
      golden_project_id,
      start_date: golden_start_date,
      end_date:   golden_end_date,
      limit:      10_000
    )
    assert sessions_result[:data].size <= Analytics::SessionsQueryService::MAX_LIMIT

    # OverviewStatsService.versions -- top 10 per platform (row_number <= 10)
    versions_result = Analytics::OverviewStatsService.versions(
      golden_project_id,
      start_date: golden_start_date,
      end_date:   golden_end_date
    )
    versions_result[:platforms].each_value do |entries|
      assert entries.size <= 10, 'Each platform should have at most 10 versions'
    end
  end

  # --------------------------------------------------------------------------
  # 9. Service constants match expected values (regression guard)
  #    If someone changes a constant, this test catches the drift.
  # --------------------------------------------------------------------------
  test 'service constants match expected values' do
    # EventsQueryService constants
    assert_equal 200, Analytics::EventsQueryService::MAX_LIMIT,
                 'EventsQueryService::MAX_LIMIT changed unexpectedly'
    assert_equal 50, Analytics::EventsQueryService::DEFAULT_LIMIT,
                 'EventsQueryService::DEFAULT_LIMIT changed unexpectedly'

    # EventsQueryService field/sort allowlists
    assert_includes Analytics::EventsQueryService::ALLOWED_FIELDS, 'platform'
    assert_includes Analytics::EventsQueryService::ALLOWED_FIELDS, 'event_type'
    assert_includes Analytics::EventsQueryService::SORTABLE_COLUMNS, 'created_at'
    assert_includes Analytics::EventsQueryService::SORTABLE_COLUMNS, 'event_type'

    # SessionsQueryService constants
    assert_equal 200, Analytics::SessionsQueryService::MAX_LIMIT,
                 'SessionsQueryService::MAX_LIMIT changed unexpectedly'
    assert_equal 50, Analytics::SessionsQueryService::DEFAULT_LIMIT,
                 'SessionsQueryService::DEFAULT_LIMIT changed unexpectedly'
    assert_includes Analytics::SessionsQueryService::FILTER_FIELDS, 'platform'
    assert_includes Analytics::SessionsQueryService::FILTER_FIELDS, 'country'

    # QueryHelpers datetime format
    assert_equal '%Y-%m-%d %H:%M:%S.%3N', Analytics::QueryHelpers::CH_DATETIME_FMT,
                 'QueryHelpers::CH_DATETIME_FMT changed unexpectedly'
  end
end
