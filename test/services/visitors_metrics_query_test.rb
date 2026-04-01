require "test_helper"

class VisitorsMetricsQueryTest < ActiveSupport::TestCase
  fixtures :projects, :instances

  setup do
    @project = projects(:one)
    @pid = @project.id

    # Create daily active user records
    ProjectDailyActiveUser.create!(project: @project, event_date: Date.new(2026, 3, 1), active_users: 100)
    ProjectDailyActiveUser.create!(project: @project, event_date: Date.new(2026, 3, 2), active_users: 150)
    ProjectDailyActiveUser.create!(project: @project, event_date: Date.new(2026, 3, 4), active_users: 120)
    # Intentionally skip Mar 3 to test gap filling
  end

  test "daily_metrics returns counts keyed by date string" do
    result = VisitorsMetricsQuery.new(
      project_ids: [@pid],
      start_date: "2026-03-01",
      end_date: "2026-03-04"
    ).call

    values = result[:metrics_values]
    assert_equal 100, values["2026-03-01"]
    assert_equal 150, values["2026-03-02"]
    assert_equal 120, values["2026-03-04"]
  end

  test "gap fills missing days with zero" do
    result = VisitorsMetricsQuery.new(
      project_ids: [@pid],
      start_date: "2026-03-01",
      end_date: "2026-03-04"
    ).call

    values = result[:metrics_values]
    assert_equal 0, values["2026-03-03"]  # no data for this day
  end

  test "returns all dates in range even with no data" do
    result = VisitorsMetricsQuery.new(
      project_ids: [@pid],
      start_date: "2020-01-01",
      end_date: "2020-01-05"
    ).call

    values = result[:metrics_values]
    assert_equal 5, values.size
    values.each_value { |v| assert_equal 0, v }
  end

  test "aggregates across multiple projects" do
    other_project = projects(:two)
    ProjectDailyActiveUser.create!(project: other_project, event_date: Date.new(2026, 3, 1), active_users: 50)

    result = VisitorsMetricsQuery.new(
      project_ids: [@pid, other_project.id],
      start_date: "2026-03-01",
      end_date: "2026-03-01"
    ).call

    assert_equal 150, result[:metrics_values]["2026-03-01"]  # 100 + 50
  end

  test "single day range returns single entry" do
    result = VisitorsMetricsQuery.new(
      project_ids: [@pid],
      start_date: "2026-03-01",
      end_date: "2026-03-01"
    ).call

    assert_equal 1, result[:metrics_values].size
    assert_equal 100, result[:metrics_values]["2026-03-01"]
  end

  test "nonexistent project_ids returns zeros" do
    result = VisitorsMetricsQuery.new(
      project_ids: [999_999],
      start_date: "2026-03-01",
      end_date: "2026-03-02"
    ).call

    result[:metrics_values].each_value { |v| assert_equal 0, v }
  end

  test "start_date equals end_date equals today returns single entry" do
    today = Date.today
    ProjectDailyActiveUser.create!(project: @project, event_date: today, active_users: 42)

    result = VisitorsMetricsQuery.new(
      project_ids: [@pid],
      start_date: today.to_s,
      end_date: today.to_s
    ).call

    values = result[:metrics_values]
    assert_equal 1, values.size
    assert_equal 42, values[today.to_s]
  end

  test "empty project_ids array returns zeros for all dates" do
    result = VisitorsMetricsQuery.new(
      project_ids: [],
      start_date: "2026-03-01",
      end_date: "2026-03-03"
    ).call

    values = result[:metrics_values]
    assert_equal 3, values.size
    values.each_value { |v| assert_equal 0, v }
  end

  # ---------------------------------------------------------------------------
  # monthly_metrics (private, currently unused by #call — but code exists)
  # ---------------------------------------------------------------------------

  test "monthly_metrics aggregates active_users by month via DATE_TRUNC" do
    # Setup: data spanning 3 months
    ProjectDailyActiveUser.create!(project: @project, event_date: Date.new(2026, 1, 10), active_users: 40)
    ProjectDailyActiveUser.create!(project: @project, event_date: Date.new(2026, 1, 20), active_users: 60)
    ProjectDailyActiveUser.create!(project: @project, event_date: Date.new(2026, 2, 5),  active_users: 80)
    # March data already exists from setup (100 + 150 + 120 = 370)

    query = VisitorsMetricsQuery.new(
      project_ids: [@pid],
      start_date: "2026-01-01",
      end_date: "2026-03-31"
    )
    result = query.send(:monthly_metrics)

    values = result[:metrics_values]
    assert_equal 3, values.size
    assert_equal 100, values["2026-01-01"]  # 40 + 60
    assert_equal 80,  values["2026-02-01"]
    assert_equal 370, values["2026-03-01"]  # 100 + 150 + 120
  end

  test "monthly_metrics zero-fills months with no data" do
    query = VisitorsMetricsQuery.new(
      project_ids: [@pid],
      start_date: "2026-01-01",
      end_date: "2026-03-31"
    )
    result = query.send(:monthly_metrics)
    values = result[:metrics_values]

    # Jan and Feb have no data from setup
    assert_equal 0, values["2026-01-01"]
    assert_equal 0, values["2026-02-01"]
  end

  test "monthly_metrics keys are month-start date strings" do
    query = VisitorsMetricsQuery.new(
      project_ids: [@pid],
      start_date: "2026-03-15",
      end_date: "2026-05-10"
    )
    result = query.send(:monthly_metrics)
    values = result[:metrics_values]

    assert_equal %w[2026-03-01 2026-04-01 2026-05-01], values.keys.sort
  end

  test "monthly_metrics aggregates across multiple projects" do
    other = projects(:two)
    ProjectDailyActiveUser.create!(project: other, event_date: Date.new(2026, 3, 1), active_users: 25)

    query = VisitorsMetricsQuery.new(
      project_ids: [@pid, other.id],
      start_date: "2026-03-01",
      end_date: "2026-03-31"
    )
    result = query.send(:monthly_metrics)

    # 100 + 150 + 120 (project one) + 25 (project two) = 395
    assert_equal 395, result[:metrics_values]["2026-03-01"]
  end

  test "monthly_metrics single month range returns one entry" do
    query = VisitorsMetricsQuery.new(
      project_ids: [@pid],
      start_date: "2026-03-01",
      end_date: "2026-03-31"
    )
    result = query.send(:monthly_metrics)

    assert_equal 1, result[:metrics_values].size
  end
end
