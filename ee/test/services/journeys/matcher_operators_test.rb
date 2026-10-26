require "test_helper"

class Journeys::MatcherOperatorsTest < ActiveSupport::TestCase
  def check(actual, operator, expected) = Journeys::Matcher.compare(actual, operator, expected)

  test "neq compares numbers as numbers and text without case, and never passes on a missing value" do
    assert_not check("10", "neq", 10.0)
    assert_not check("Gold", "neq", "gOLD")
    assert check("Gold", "neq", "Silver")
    assert check("10", "neq", "10.5")
    assert_not check(nil, "neq", "Gold")
    assert_not check("", "neq", "Gold")
  end

  test "gt and lt are numeric only: text never orders, and the bounds are strict" do
    assert check("30", "gt", 10)
    assert_not check("10", "gt", 10)
    assert check("-2.5", "lt", "-2")
    assert_not check("10", "lt", "10")
    assert_not check("b", "gt", "a")
    assert_not check("b", "lt", "c")
    assert_not check("9", "gt", "abc")
    assert check("100", "gt", "99"), "never a string comparison, where '100' sorts before '99'"
  end

  test "contains and not_contains ignore case; a missing value passes neither" do
    assert check("Spring Sale", "contains", "SALE")
    assert_not check("Spring Sale", "contains", "winter")
    assert check("Spring Sale", "not_contains", "winter")
    assert_not check("Spring Sale", "not_contains", "sPrInG")
    assert_not check(nil, "contains", "x")
    assert_not check(nil, "not_contains", "x")
  end

  test "an unknown operator, or a missing expected value, never passes" do
    assert_not check("Gold", "matches", "Gold")
    assert_not check("Gold", "eq", nil)
    assert_not check("Gold", "eq", { "a" => 1 })
  end

  test "objects and lists are unset values: only is_not_set passes for them" do
    [{ "a" => 1 }, [1, 2]].each do |value|
      assert check(value, "is_not_set", nil)
      assert_not check(value, "is_set", nil)
      assert_not check(value, "eq", value.to_s)
    end
  end

  test "floats read as a device writes them: whole ones without a fraction, small ones without an exponent" do
    assert_equal "3", Journeys::Matcher.text(3.0)
    assert_equal "0.00001", Journeys::Matcher.text(1.0e-5)
    assert_equal "2.5", Journeys::Matcher.text(2.50)
    assert check(3.0, "eq", "3")
    assert check(1.0e-5, "gt", 0)
    assert check(true, "eq", "TRUE")
  end

  test "between is inclusive, reads string bounds, and refuses a malformed range" do
    assert check("10", "between", [10, 20])
    assert check(20, "between", ["10", "20"])
    assert_not check("20.01", "between", [10, 20])
    assert_not check("15", "between", [10])
    assert_not check("15", "between", "10-20")
    assert_not check("15", "between", [10, "x"])
    assert_not check("abc", "between", [10, 20])
  end

  test "pass? needs every filter to hold, and passes with none" do
    filters = [{ "field" => "plan", "op" => "eq", "value" => "gold" }, { "field" => "total", "op" => "gt", "value" => 5 }]
    assert Journeys::Matcher.pass?(filters, { "plan" => "Gold", "total" => 9 })
    assert_not Journeys::Matcher.pass?(filters, { "plan" => "Gold", "total" => 5 })
    assert Journeys::Matcher.pass?(nil, {})
  end
end
