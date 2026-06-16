require "test_helper"

class MigrationLookupResultTest < ActiveSupport::TestCase
  test "found factory sets outcome and payload" do
    r = MigrationLookupResult.found({ "og_title" => "x" })
    assert_equal :found, r.outcome
    assert_equal 200, r.http_status
    assert_equal "x", r.payload["og_title"]
  end

  test "not_found factory" do
    r = MigrationLookupResult.not_found
    assert_equal :not_found, r.outcome
    assert_equal 404, r.http_status
  end

  test "transient_error factory carries http_status" do
    r = MigrationLookupResult.transient_error(http_status: 503)
    assert_equal :transient_error, r.outcome
    assert_equal 503, r.http_status
    assert_nil r.retry_after
  end

  # ---------------------------------------------------------------------------
  # parse_retry_after: defensive cases
  # ---------------------------------------------------------------------------

  test "parse_retry_after returns nil for nil" do
    assert_nil MigrationLookupResult.parse_retry_after(nil)
  end

  test "parse_retry_after returns nil for blank string" do
    assert_nil MigrationLookupResult.parse_retry_after("")
    assert_nil MigrationLookupResult.parse_retry_after("   ")
  end

  test "parse_retry_after returns nil for '0'" do
    assert_nil MigrationLookupResult.parse_retry_after("0")
  end

  test "parse_retry_after returns nil for negative values" do
    assert_nil MigrationLookupResult.parse_retry_after("-5")
    assert_nil MigrationLookupResult.parse_retry_after(-10)
  end

  test "parse_retry_after returns nil for non-numeric garbage" do
    assert_nil MigrationLookupResult.parse_retry_after("garbage")
  end

  test "parse_retry_after clamps low values to MIN" do
    assert_equal MigrationLookupResult::RETRY_AFTER_MIN_SECONDS, MigrationLookupResult.parse_retry_after("2")
  end

  test "parse_retry_after clamps high values to MAX" do
    assert_equal MigrationLookupResult::RETRY_AFTER_MAX_SECONDS, MigrationLookupResult.parse_retry_after("99999")
  end

  test "parse_retry_after accepts integers" do
    assert_equal 30, MigrationLookupResult.parse_retry_after(30)
  end

  test "parse_retry_after accepts numeric strings" do
    assert_equal 30, MigrationLookupResult.parse_retry_after("30")
  end

  test "parse_retry_after handles HTTP-date format" do
    future = 90.seconds.from_now
    result = MigrationLookupResult.parse_retry_after(future.httpdate)
    assert_in_delta 90, result, 5
  end

  test "transient_error factory normalizes retry_after via parse" do
    r = MigrationLookupResult.transient_error(http_status: 429, retry_after: "0")
    assert_nil r.retry_after  # zero rejected
    r2 = MigrationLookupResult.transient_error(http_status: 429, retry_after: "30")
    assert_equal 30, r2.retry_after
  end

  test "probe_outcome: not_found means creds work, found is unexpected" do
    assert_equal MigrationLookupResult::PROBE_OK,
                 MigrationLookupResult.not_found.probe_outcome
    assert_equal MigrationLookupResult::PROBE_UNEXPECTED,
                 MigrationLookupResult.found({}).probe_outcome
  end

  test "probe_outcome: 400/401/403 are credentials_invalid" do
    [400, 401, 403].each do |status|
      assert_equal MigrationLookupResult::PROBE_INVALID,
                   MigrationLookupResult.transient_error(http_status: status).probe_outcome,
                   "HTTP #{status} should map to credentials_invalid"
    end
  end

  test "probe_outcome: 429 is rate_limited, other transient is unreachable" do
    assert_equal MigrationLookupResult::PROBE_RATE_LIMITED,
                 MigrationLookupResult.transient_error(http_status: 429).probe_outcome
    assert_equal MigrationLookupResult::PROBE_UNREACHABLE,
                 MigrationLookupResult.transient_error(http_status: 500).probe_outcome
    assert_equal MigrationLookupResult::PROBE_UNREACHABLE,
                 MigrationLookupResult.transient_error(http_status: 0).probe_outcome
  end
end
