require "test_helper"

class ProjectServiceTest < ActiveSupport::TestCase
  fixtures :instances, :projects, :visitors, :devices, :visitor_daily_statistics

  setup do
    @service = ProjectService.new
    @instance = instances(:one)
    @project = projects(:one) # production project for instance :one (test: false)

    # Instance :one needs a test project for compute_mau_for_dates to work
    # (it checks instance.test and instance.production; both must be non-nil)
    @test_project = Project.create!(
      name: "Test Project Test Env",
      identifier: "test-project-001-test",
      instance: @instance,
      test: true
    )

    # Clear fixture data and create controlled test data so counts
    # don't break when someone adds a new fixture to visitor_daily_statistics.yml
    VisitorDailyStatistic.where(project_id: @project.id).delete_all

    # 3 stats: ios_visitor on day1+day2, android_visitor on day1
    # => 2 distinct visitors in March
    VisitorDailyStatistic.create!(visitor: visitors(:ios_visitor), project_id: @project.id,
      event_date: "2026-03-01", platform: "ios",
      views: 50, opens: 20, installs: 5, reinstalls: 1,
      time_spent: 3000, revenue: 500, reactivations: 0, app_opens: 10, user_referred: 2)
    VisitorDailyStatistic.create!(visitor: visitors(:ios_visitor), project_id: @project.id,
      event_date: "2026-03-02", platform: "ios",
      views: 80, opens: 30, installs: 8, reinstalls: 2,
      time_spent: 5000, revenue: 800, reactivations: 1, app_opens: 20, user_referred: 4)
    VisitorDailyStatistic.create!(visitor: visitors(:android_visitor), project_id: @project.id,
      event_date: "2026-03-01", platform: "android",
      views: 30, opens: 10, installs: 3, reinstalls: 0,
      time_spent: 2000, revenue: 300, reactivations: 0, app_opens: 8, user_referred: 1)
  end

  # --- compute_mau_for_dates ---

  test "compute_mau_for_dates counts distinct visitors across test and production projects" do
    start_date = Date.new(2026, 3, 1).beginning_of_day
    end_date = Date.new(2026, 3, 31).end_of_day

    # Fixtures have ios_visitor (2 stats: day1+day2) and android_visitor (1 stat: day1)
    # Both on project :one (production). They are distinct visitors => 2
    result = @service.send(:compute_mau_for_dates, @instance, start_date, end_date)
    assert_equal 2, result
  end

  test "compute_mau_for_dates returns 0 when instance is nil" do
    start_date = Date.new(2026, 3, 1).beginning_of_day
    end_date = Date.new(2026, 3, 31).end_of_day

    result = @service.send(:compute_mau_for_dates, nil, start_date, end_date)
    assert_equal 0, result
  end

  test "compute_mau_for_dates returns 0 when instance has no test project" do
    # Instance :two has project :two (production) but no test project
    instance_two = instances(:two)

    start_date = Date.new(2026, 3, 1).beginning_of_day
    end_date = Date.new(2026, 3, 31).end_of_day

    result = @service.send(:compute_mau_for_dates, instance_two, start_date, end_date)
    assert_equal 0, result
  end

  test "compute_mau_for_dates returns 0 when no stats exist in date range" do
    # April has no fixture stats
    start_date = Date.new(2026, 4, 1).beginning_of_day
    end_date = Date.new(2026, 4, 30).end_of_day

    result = @service.send(:compute_mau_for_dates, @instance, start_date, end_date)
    assert_equal 0, result
  end

  # --- compute_maus_per_month_total ---

  test "compute_maus_per_month_total sums MAUs across multiple months" do
    # Create a stat in February so there's data across two months
    feb_visitor = visitors(:ios_visitor)
    VisitorDailyStatistic.create!(
      visitor: feb_visitor,
      project_id: @project.id,
      event_date: Date.new(2026, 2, 15),
      platform: "ios",
      views: 10, opens: 5, installs: 0, reinstalls: 0,
      time_spent: 0, revenue: 0, reactivations: 0, app_opens: 0, user_referred: 0
    )

    start_date = Date.new(2026, 2, 1)
    end_date = Date.new(2026, 3, 31)

    result = @service.compute_maus_per_month_total(@instance, start_date, end_date)

    # Feb: 1 distinct visitor (ios_visitor)
    # Mar: 2 distinct visitors (ios_visitor + android_visitor from fixtures)
    # Total = 1 + 2 = 3
    assert_equal 3, result
  end

  test "compute_maus_per_month_total handles single-month range" do
    start_date = Date.new(2026, 3, 1)
    end_date = Date.new(2026, 3, 31)

    result = @service.compute_maus_per_month_total(@instance, start_date, end_date)

    # Mar: 2 distinct visitors (ios_visitor + android_visitor)
    assert_equal 2, result
  end

  # --- current_mau ---

  test "current_mau returns MAU for the current month" do
    travel_to Date.new(2026, 3, 15) do
      result = @service.current_mau(@instance)

      # March 2026 has fixture stats: ios_visitor + android_visitor = 2
      assert_equal 2, result
    end
  end

  # --- last_month_mau ---

  test "last_month_mau returns MAU for the previous month" do
    # Create a stat in February
    VisitorDailyStatistic.create!(
      visitor: visitors(:ios_visitor),
      project_id: @project.id,
      event_date: Date.new(2026, 2, 10),
      platform: "ios",
      views: 5, opens: 2, installs: 0, reinstalls: 0,
      time_spent: 0, revenue: 0, reactivations: 0, app_opens: 0, user_referred: 0
    )

    travel_to Date.new(2026, 3, 15) do
      result = @service.last_month_mau(@instance)

      # February 2026: 1 distinct visitor (ios_visitor)
      assert_equal 1, result
    end
  end

  test "last_month_mau returns 0 when no stats exist for previous month" do
    travel_to Date.new(2026, 3, 15) do
      result = @service.last_month_mau(@instance)

      # February 2026 has no fixture stats
      assert_equal 0, result
    end
  end
end
