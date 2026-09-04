# frozen_string_literal: true

require 'test_helper'

# Regression guard for ClickHouse query counts per analytics service call.
# Uses ChQueryCounter to instrument queries via ActiveSupport::Notifications
# ('sql.click_house' event) and asserts exact or bounded counts.
#
# The golden base dataset is loaded so every query actually executes against
# real CH data and returns real results -- we're counting *real* round-trips,
# not mocked calls.
#
# If a count changes, it means someone added or removed a CH query in the
# service layer. Update the assertion and document the reason in a comment.
class Analytics::QueryCountTest < ActiveSupport::TestCase
  include ClickhouseTestHelper
  include GoldenDatasetHelper
  include ChQueryCounter

  fixtures :projects, :instances

  setup do
    skip_unless_clickhouse!
    setup_golden_dataset
    @project = golden_project
    # Clear any cached computed values so query counts are deterministic.
    Rails.cache.clear
  end

  teardown { teardown_golden_dataset }

  # -------------------------------------------------------------------------
  # 1. events#list without include_count uses exactly 1 read query
  # -------------------------------------------------------------------------
  # EventsQueryService.list builds a single SELECT ... FROM events query
  # when include_count is false (the default). No count query is run.
  test 'events list without include_count executes exactly 1 read query' do
    n = count_ch_queries do
      Analytics::EventsQueryService.list(
        @project.id,
        start_date: golden_start_date,
        end_date:   golden_end_date,
        include_count: false
      )
    end

    assert_equal 1, n, "Expected exactly 1 CH read for events#list without count, got #{n}"
  end

  # -------------------------------------------------------------------------
  # 2. events#list with include_count=true uses exactly 2 read queries
  # -------------------------------------------------------------------------
  # When include_count is true, the service runs the data SELECT (select_all)
  # followed by a separate COUNT() query (select_value). Total: 2 reads.
  test 'events list with include_count executes exactly 2 read queries' do
    n = count_ch_queries do
      Analytics::EventsQueryService.list(
        @project.id,
        start_date:    golden_start_date,
        end_date:      golden_end_date,
        include_count: true
      )
    end

    assert_equal 2, n, "Expected exactly 2 CH reads for events#list with count, got #{n}"
  end

  # -------------------------------------------------------------------------
  # 3. events#volume uses exactly 1 read query
  # -------------------------------------------------------------------------
  # Volume builds a single GROUP BY bucket query -- one select_all call.
  test 'events volume executes exactly 1 read query' do
    n = count_ch_queries do
      Analytics::EventsQueryService.volume(
        @project.id,
        start_date: golden_start_date,
        end_date:   golden_end_date,
        bucket:     'day'
      )
    end

    assert_equal 1, n, "Expected exactly 1 CH read for events#volume, got #{n}"
  end

  # -------------------------------------------------------------------------
  # 8. retention summary has a known bounded query count
  # -------------------------------------------------------------------------
  # RetentionService.summary calls compute_summary which executes 2 reads
  # inside one Clickhouse.with block:
  #   1. select_all for rates (D1/D3/D7/D14/D30/D60/D90 all in one query)
  #   2. select_all for sparkline (daily D1 rates for last 30 days)
  # Total: exactly 2 reads.
  test 'retention summary executes exactly 2 read queries' do
    n = count_ch_queries do
      Analytics::RetentionService.summary(@project.id)
    end

    assert_equal 2, n, "Expected exactly 2 CH reads for retention#summary, got #{n}"
  end

  # -------------------------------------------------------------------------
  # 9. field_values uses exactly 1 read query
  # -------------------------------------------------------------------------
  # EventsQueryService.field_values runs a single SELECT DISTINCT query.
  test 'field_values executes exactly 1 read query' do
    n = count_ch_queries do
      Analytics::EventsQueryService.field_values(@project.id, field: 'platform',
                                                 start_date: golden_start_date, end_date: golden_end_date)
    end

    assert_equal 1, n, "Expected exactly 1 CH read for field_values, got #{n}"
  end
end
