# frozen_string_literal: true

require 'test_helper'

# REAL ClickHouse tests for the with_guard query helper.
#
# Unlike the stubbed mapping tests in query_helpers_test.rb / query_guard_test.rb,
# these execute against a live ClickHouse so they prove two things a stub cannot:
#   1. the appended GUARD `SETTINGS` clause is actually VALID against the running
#      CH build (a bogus setting → Code 115 UNKNOWN_SETTING, which no stub catches);
#   2. the HEAVY regex matches the ACTUAL timeout/memory error text emitted by CH,
#      not a hand-guessed string.
class Analytics::QueryGuardRealTest < ActiveSupport::TestCase
  include ClickhouseTestHelper

  setup { skip_unless_clickhouse! }

  # (a) Happy path — the exact test that would have caught the `wait_end_of_query`
  # bug: a real query through with_guard must succeed, which is only possible if
  # the appended SETTINGS clause parses on this CH build.
  test 'with_guard executes a real query against ClickHouse and returns rows (SETTINGS clause is valid)' do
    result = Analytics::EventsQueryService.send(:with_guard, 'SELECT 1 AS n').to_a
    assert_equal 1, result.first['n'].to_i
  end

  # (b) Real timeout → HEAVY match. Forces a genuine Code 159 / TIMEOUT_EXCEEDED
  # by bypassing the 25s GUARD with a 1s max_execution_time, then asserts the
  # HEAVY regex matches the real message format CH 26.x emits.
  test 'HEAVY regex matches a real ClickHouse timeout error message' do
    err = assert_raises(ClickHouse::Client::DatabaseError) do
      Clickhouse.with do |c|
        c.select_all("SELECT sleep(3) SETTINGS max_execution_time = 1, timeout_overflow_mode = 'throw'")
      end
    end
    assert_match Analytics::QueryHelpers::HEAVY, err.message,
                 "real CH timeout message did not match HEAVY: #{err.message}"
  end

  # (b') Real memory cap → HEAVY match. Forces a genuine Code 241 /
  # MEMORY_LIMIT_EXCEEDED so the 241 branch of HEAVY is validated against the
  # real message format too (not just the 159 branch).
  test 'HEAVY regex matches a real ClickHouse memory-limit error message' do
    err = assert_raises(ClickHouse::Client::DatabaseError) do
      Clickhouse.with do |c|
        c.select_all(
          'SELECT count() FROM (SELECT number, groupArray(number) FROM numbers(50000000) GROUP BY number) ' \
          'SETTINGS max_memory_usage = 1000000, max_bytes_before_external_group_by = 0'
        )
      end
    end
    assert_match Analytics::QueryHelpers::HEAVY, err.message,
                 "real CH memory message did not match HEAVY: #{err.message}"
  end

  # (a') End-to-end mapping against real CH: a real timeout routed THROUGH
  # with_guard is mapped to Analytics::QueryTooHeavy, proving the rescue branch
  # fires on the real error — not just on a stubbed string. The 1s
  # max_execution_time overrides the GUARD's 25s so the query trips quickly.
  test 'with_guard maps a real ClickHouse timeout to QueryTooHeavy' do
    sql = "SELECT sleep(3) SETTINGS max_execution_time = 1, timeout_overflow_mode = 'throw'"
    assert_raises(Analytics::QueryTooHeavy) do
      Analytics::EventsQueryService.send(:with_guard, sql)
    end
  end

  # A streaming abort produces a fundamentally different error shape than a
  # pre-stream timeout: CH has already flushed a 200 response with a partial
  # JSON body, THEN aborts mid-stream when max_execution_time trips. The
  # resulting DatabaseError message STARTS with the partial JSON body
  # (`{"meta"...`) and only mentions `Code: 159` / `TIMEOUT_EXCEEDED` near the
  # END (verified: ~char 2318 of a ~2456-char message on CH 26.x). HEAVY still
  # matches because String#match? scans the whole message — these tests pin
  # that behavior so anchoring the regex (e.g. `/\ACode:/`) can't silently
  # break the streaming-abort → QueryTooHeavy mapping.
  #
  # Per-row sleep + tiny blocks force CH to stream a 200 body before aborting.
  STREAMING_ABORT_SQL =
    'SELECT number FROM numbers(100000000) WHERE sleepEachRow(0.01) = 0 ' \
    'SETTINGS max_execution_time = 1, max_block_size = 5'

  # (c) End-to-end: a streaming abort routed through with_guard is mapped to
  # QueryTooHeavy. with_guard appends its own `SETTINGS max_execution_time = 25,
  # ...`; the query's inline `max_execution_time = 1` still trips first (~1s),
  # so the doubled-SETTINGS clause is exercised against real CH too.
  test 'with_guard maps a streaming-abort timeout (buried Code 159) to QueryTooHeavy' do
    assert_raises(Analytics::QueryTooHeavy) do
      Analytics::EventsQueryService.send(:with_guard, STREAMING_ABORT_SQL)
    end
  end

  # (c') Regex-level proof of the buried-error shape. Runs the streaming query
  # DIRECTLY (only its own SETTINGS) and asserts BOTH:
  #   (a) the message STARTS with `{` — the stream actually began, so this is
  #       the 200-then-abort case, NOT a pre-stream error; and
  #   (b) HEAVY matches the full message even though Code 159 is buried far from
  #       the start.
  # This is the assertion that fails if someone anchors HEAVY to the start.
  test 'HEAVY matches a streaming-abort message whose Code 159 is buried after the JSON body' do
    err = assert_raises(ClickHouse::Client::DatabaseError) do
      Clickhouse.with { |c| c.select_all(STREAMING_ABORT_SQL) }
    end

    assert err.message.lstrip.start_with?('{'),
           "expected a streamed (200-then-abort) body starting with '{', got: #{err.message[0, 80].inspect}"
    assert_match Analytics::QueryHelpers::HEAVY, err.message,
                 "HEAVY did not match the buried-error streaming-abort message: #{err.message[-120..]}"
    # Sanity: the match is NOT at the very start (proves the buried-error case,
    # which a start-anchored regex would miss).
    assert_operator(err.message =~ Analytics::QueryHelpers::HEAVY, :>, 0,
                    'expected Code 159 buried after the streamed body, not at char 0')
  end
end
