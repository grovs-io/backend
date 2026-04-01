require "test_helper"

class DailyProjectMetricsBackfillServiceTest < ActiveSupport::TestCase
  test "calls DailyProjectMetricsGenerator once per date in range" do
    called_dates = []
    DailyProjectMetricsGenerator.stub(:call, ->(date) { called_dates << date }) do
      DailyProjectMetricsBackfillService.call(
        start_date: Date.new(2026, 3, 1),
        end_date:   Date.new(2026, 3, 3)
      )
    end

    assert_equal [Date.new(2026, 3, 1), Date.new(2026, 3, 2), Date.new(2026, 3, 3)], called_dates
  end

  test "end_date defaults to today" do
    called_dates = []
    DailyProjectMetricsGenerator.stub(:call, ->(date) { called_dates << date }) do
      DailyProjectMetricsBackfillService.call(start_date: Date.today)
    end

    assert_equal [Date.today], called_dates
  end
end
