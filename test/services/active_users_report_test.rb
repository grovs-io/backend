require "test_helper"
require "csv"

class ActiveUsersReportTest < ActiveSupport::TestCase
  fixtures :instances, :visitor_daily_statistics, :visitors, :projects, :devices

  setup do
    @project_id = projects(:one).id

    # Clear fixture data and create controlled test data so counts
    # don't break when someone adds a new fixture to visitor_daily_statistics.yml
    VisitorDailyStatistic.where(project_id: @project_id).delete_all

    # 3 stats: ios_visitor on day1+day2, android_visitor on day1
    # Day1: 2 distinct visitors, Day2: 1 distinct visitor, Month: 2 distinct
    VisitorDailyStatistic.create!(visitor: visitors(:ios_visitor), project_id: @project_id,
      event_date: "2026-03-01", platform: "ios",
      views: 50, opens: 20, installs: 5, reinstalls: 1,
      time_spent: 3000, revenue: 500, reactivations: 0, app_opens: 10, user_referred: 2)
    VisitorDailyStatistic.create!(visitor: visitors(:ios_visitor), project_id: @project_id,
      event_date: "2026-03-02", platform: "ios",
      views: 80, opens: 30, installs: 8, reinstalls: 2,
      time_spent: 5000, revenue: 800, reactivations: 1, app_opens: 20, user_referred: 4)
    VisitorDailyStatistic.create!(visitor: visitors(:android_visitor), project_id: @project_id,
      event_date: "2026-03-01", platform: "android",
      views: 30, opens: 10, installs: 3, reinstalls: 0,
      time_spent: 2000, revenue: 300, reactivations: 0, app_opens: 8, user_referred: 1)
  end

  test "raises ArgumentError when start_date > end_date" do
    assert_raises(ArgumentError) do
      ActiveUsersReport.new(
        project_ids: @project_id,
        start_date: Date.new(2026, 3, 5),
        end_date: Date.new(2026, 3, 1)
      )
    end
  end

  test "daily counts are distinct visitors per day" do
    csv = ActiveUsersReport.new(
      project_ids: @project_id,
      start_date: Date.new(2026, 3, 1),
      end_date: Date.new(2026, 3, 2)
    ).call

    daily = extract_daily_rows(csv)

    # 2026-03-01: ios_visitor + android_visitor = 2 distinct
    # 2026-03-02: ios_visitor only = 1 distinct
    assert_equal 2, daily["2026-03-01"]
    assert_equal 1, daily["2026-03-02"]
  end

  test "monthly count is distinct visitors across the whole month, not sum of daily" do
    csv = ActiveUsersReport.new(
      project_ids: @project_id,
      start_date: Date.new(2026, 3, 1),
      end_date: Date.new(2026, 3, 2)
    ).call

    monthly = extract_monthly_rows(csv)

    # ios_visitor appears on both days but should count as 1 monthly unique
    # android_visitor appears on day 1 only = 1 monthly unique
    # Total distinct for March: 2 (not 3 which would be sum-of-daily)
    assert_equal 2, monthly["2026-03"]
  end

  test "dates with no data are zero-filled" do
    csv = ActiveUsersReport.new(
      project_ids: @project_id,
      start_date: Date.new(2026, 4, 1),
      end_date: Date.new(2026, 4, 3)
    ).call

    daily = extract_daily_rows(csv)

    assert_equal 3, daily.size
    assert daily.values.all?(&:zero?), "All April dates should be 0"
  end

  test "months with no data are zero-filled" do
    csv = ActiveUsersReport.new(
      project_ids: @project_id,
      start_date: Date.new(2026, 4, 1),
      end_date: Date.new(2026, 4, 30)
    ).call

    monthly = extract_monthly_rows(csv)
    assert_equal 0, monthly["2026-04"]
  end

  test "CSV contains all three sections: total, monthly, daily" do
    csv = ActiveUsersReport.new(
      project_ids: @project_id,
      start_date: Date.new(2026, 3, 1),
      end_date: Date.new(2026, 3, 1)
    ).call

    parsed = CSV.parse(csv)
    headers = parsed.map(&:first)

    assert_includes headers, "Sum of Monthly Unique Active Users"
    assert_includes headers, "Month"
    assert_includes headers, "Date"
  end

  test "multiple project_ids aggregates visitors across projects" do
    # Both fixture stats are for project :one, so adding :two shouldn't change counts
    # but it proves the Array(project_ids) wrapping works
    csv = ActiveUsersReport.new(
      project_ids: [projects(:one).id, projects(:two).id],
      start_date: Date.new(2026, 3, 1),
      end_date: Date.new(2026, 3, 1)
    ).call

    daily = extract_daily_rows(csv)
    assert_equal 2, daily["2026-03-01"]
  end

  private

  def extract_daily_rows(csv_string)
    parsed = CSV.parse(csv_string)
    daily_idx = parsed.index { |r| r.first == "Date" }
    parsed[(daily_idx + 1)..].to_h { |r| [r[0], r[1].to_i] }
  end

  def extract_monthly_rows(csv_string)
    parsed = CSV.parse(csv_string)
    monthly_idx = parsed.index { |r| r.first == "Month" }
    # Monthly rows end at the next blank separator row
    rows = []
    (monthly_idx + 1...parsed.size).each do |i|
      break if parsed[i].compact.empty?
      rows << parsed[i]
    end
    rows.to_h { |r| [r[0], r[1].to_i] }
  end
end
