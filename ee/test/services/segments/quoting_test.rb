require "test_helper"

class SegmentsQuotingTest < ActiveSupport::TestCase
  test "literal escapes quotes and backslashes" do
    assert_equal "'o\\'brien\\\\'", Segments::Quoting.literal("o'brien\\")
  end

  test "is builds an IN list and is_not a NOT IN list" do
    assert_equal "col IN ('a', 'b')", Segments::Quoting.string_clause("col", "is", %w[a b])
    assert_equal "col NOT IN ('a')", Segments::Quoting.string_clause("col", "is_not", ["a"])
  end

  test "contains lower-cases and escapes LIKE wildcards" do
    assert_equal "lower(col) LIKE '%50\\\\%off%'", Segments::Quoting.string_clause("col", "contains", ["50%OFF"])
  end

  test "clean_values rejects empty, oversized and over-long lists" do
    errors = []
    assert_nil Segments::Quoting.clean_values([], path: "p", errors: errors)
    assert_nil Segments::Quoting.clean_values(["x" * 257], path: "p", errors: errors)
    assert_nil Segments::Quoting.clean_values(Array.new(101, "a"), path: "p", errors: errors)
    assert_equal 3, errors.size
    assert_equal %w[a b], Segments::Quoting.clean_values(%w[b a b], path: "p", errors: [])
  end

  test "clean_values rejects non-scalar shapes and accepts a bare numeric" do
    hash_errors = []
    nested_errors = []
    assert_nil Segments::Quoting.clean_values({ "a" => "b" }, path: "p", errors: hash_errors)
    assert_equal 1, hash_errors.size
    assert_nil Segments::Quoting.clean_values([["x"]], path: "p", errors: nested_errors)
    assert_equal 1, nested_errors.size
    assert_equal ["5"], Segments::Quoting.clean_values(5, path: "p", errors: [])
  end

  test "clean_values accepts JSON booleans, stringified, and still rejects nil" do
    assert_equal ["true"], Segments::Quoting.clean_values(true, path: "p", errors: [])
    assert_equal %w[false true], Segments::Quoting.clean_values([true, false], path: "p", errors: [])
    errors = []
    assert_nil Segments::Quoting.clean_values(nil, path: "p", errors: errors)
    assert_equal 1, errors.size
  end

  test "contains with multiple values builds OR'd LIKE clauses" do
    assert_equal "(lower(col) LIKE '%foo%' OR lower(col) LIKE '%bar%')",
                 Segments::Quoting.string_clause("col", "contains", %w[Foo bar])
  end

  test "unknown operator raises ArgumentError" do
    assert_raises(ArgumentError) do
      Segments::Quoting.string_clause("col", "unknown_op", ["value"])
    end
  end

  test "strict_bool accepts only true/false booleans or their string forms" do
    assert_equal true, Segments::Quoting.strict_bool(true)
    assert_equal false, Segments::Quoting.strict_bool(false)
    assert_equal true, Segments::Quoting.strict_bool("true")
    assert_equal false, Segments::Quoting.strict_bool("false")
    assert_nil Segments::Quoting.strict_bool(1)
    assert_nil Segments::Quoting.strict_bool(0)
    assert_nil Segments::Quoting.strict_bool("yes")
    assert_nil Segments::Quoting.strict_bool(nil)
    assert_nil Segments::Quoting.strict_bool([])
  end

  test "strict_int accepts only a bare integer or an all-digit string" do
    assert_equal 5, Segments::Quoting.strict_int(5)
    assert_equal 5, Segments::Quoting.strict_int("5")
    assert_nil Segments::Quoting.strict_int(5.9)
    assert_nil Segments::Quoting.strict_int(true)
    assert_nil Segments::Quoting.strict_int(false)
    assert_nil Segments::Quoting.strict_int(nil)
    assert_nil Segments::Quoting.strict_int([1])
    assert_nil Segments::Quoting.strict_int({ "a" => 1 })
    assert_nil Segments::Quoting.strict_int("1junk")
    assert_nil Segments::Quoting.strict_int("1.9")
    assert_nil Segments::Quoting.strict_int("-1")
  end

  test "strict_flag defaults false when absent, errors and defaults false when invalid" do
    errors = []
    assert_equal false, Segments::Quoting.strict_flag({}, "negate", "p", errors)
    assert_empty errors
    assert_equal true, Segments::Quoting.strict_flag({ "negate" => "true" }, "negate", "p", errors)
    assert_empty errors
    assert_equal false, Segments::Quoting.strict_flag({ "negate" => "nope" }, "negate", "p", errors)
    assert_equal [{ path: "p.negate", message: "negate must be true or false" }], errors
  end
end
