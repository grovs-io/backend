require "test_helper"

class DateParamParserTest < ActiveSupport::TestCase
  test "parses valid ISO date string" do
    assert_equal Date.new(2026, 3, 15), DateParamParser.call("2026-03-15", default: Date.new(2000, 1, 1))
  end

  test "returns default for nil" do
    assert_equal Date.new(2026, 1, 1), DateParamParser.call(nil, default: Date.new(2026, 1, 1))
  end

  test "returns default for empty string" do
    assert_equal Date.new(2026, 1, 1), DateParamParser.call("", default: Date.new(2026, 1, 1))
  end

  test "returns default for unparseable string instead of raising" do
    assert_equal Date.today, DateParamParser.call("not-a-date", default: Date.today)
  end

  test "returns default for impossible date like Feb 30" do
    assert_equal Date.today, DateParamParser.call("2026-02-30", default: Date.today)
  end
end
