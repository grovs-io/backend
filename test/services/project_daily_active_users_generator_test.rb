require "test_helper"

class ProjectDailyActiveUsersGeneratorTest < ActiveSupport::TestCase
  fixtures :instances, :projects, :devices, :visitors, :visitor_daily_statistics

  setup do
    @project = projects(:one)
    @date = Date.new(2026, 3, 1)

    # Clean computed DAU rows for our test dates
    ProjectDailyActiveUser.where(event_date: [
      Date.new(2026, 3, 1), Date.new(2026, 3, 2),
      Date.new(2026, 6, 1)
    ]).delete_all

    # Clear fixture VDS and create controlled test data so counts
    # don't break when someone adds a new fixture to visitor_daily_statistics.yml
    VisitorDailyStatistic.where(project_id: @project.id).delete_all
    # ios_visitor on day1+day2, android_visitor on day1
    create_stat(visitors(:ios_visitor), @project, Date.new(2026, 3, 1), "ios", views: 50)
    create_stat(visitors(:ios_visitor), @project, Date.new(2026, 3, 2), "ios", views: 80)
    create_stat(visitors(:android_visitor), @project, Date.new(2026, 3, 1), "android", views: 30)
  end

  # ---------------------------------------------------------------------------
  # Basic DAU calculation — COUNT(DISTINCT visitor_id)
  # ---------------------------------------------------------------------------

  test "counts distinct visitors per project and platform" do
    # Fixtures: ios_stat_day1 (ios_visitor, ios), android_stat_day1 (android_visitor, android)
    ProjectDailyActiveUsersGenerator.call(@date)

    ios_dau = find_dau(@project, @date, "ios")
    android_dau = find_dau(@project, @date, "android")

    assert_not_nil ios_dau
    assert_equal 1, ios_dau.active_users, "One iOS visitor on 2026-03-01"

    assert_not_nil android_dau
    assert_equal 1, android_dau.active_users, "One Android visitor on 2026-03-01"
  end

  test "two distinct visitors on same platform produces count of 2" do
    second_device = create_device("ios")
    second_visitor = Visitor.create!(project: @project, device: second_device, web_visitor: false)
    create_stat(second_visitor, @project, @date, "ios", views: 10)

    ProjectDailyActiveUsersGenerator.call(@date)

    ios_dau = find_dau(@project, @date, "ios")
    assert_equal 2, ios_dau.active_users
  end

  test "same visitor on different platforms counts once per platform" do
    # ios_stat_day1 already exists for ios_visitor on ios.
    # Add a web stat for the SAME visitor.
    create_stat(visitors(:ios_visitor), @project, @date, "web", views: 5)

    ProjectDailyActiveUsersGenerator.call(@date)

    assert_equal 1, find_dau(@project, @date, "ios").active_users
    assert_equal 1, find_dau(@project, @date, "web").active_users
  end

  # ---------------------------------------------------------------------------
  # Upsert idempotency — the most important property
  # ---------------------------------------------------------------------------

  test "running twice produces identical results" do
    ProjectDailyActiveUsersGenerator.call(@date)
    first_run = dau_snapshot(@date)

    ProjectDailyActiveUsersGenerator.call(@date)
    second_run = dau_snapshot(@date)

    assert_equal first_run, second_run
  end

  test "upsert REPLACES count when underlying data changes" do
    ProjectDailyActiveUsersGenerator.call(@date)
    assert_equal 1, find_dau(@project, @date, "ios").active_users

    # Add a new visitor
    new_device = create_device("ios")
    new_visitor = Visitor.create!(project: @project, device: new_device, web_visitor: false)
    create_stat(new_visitor, @project, @date, "ios", views: 1)

    ProjectDailyActiveUsersGenerator.call(@date)

    # Must be 2, not 1+1=2 via increment. Verify by checking the value directly.
    dau = find_dau(@project, @date, "ios")
    assert_equal 2, dau.active_users, "Upsert should REPLACE, not increment"
  end

  # ---------------------------------------------------------------------------
  # Sharding — all projects covered across 16 shards
  # ---------------------------------------------------------------------------

  test "projects in different shards are all processed" do
    project_two = projects(:two)
    device_two = create_device("web")
    visitor_two = Visitor.create!(project: project_two, device: device_two, web_visitor: true)
    create_stat(visitor_two, project_two, @date, "web", views: 1)

    ProjectDailyActiveUsersGenerator.call(@date)

    assert ProjectDailyActiveUser.where(project_id: @project.id, event_date: @date).exists?,
           "Project one should have DAU rows"
    assert ProjectDailyActiveUser.where(project_id: project_two.id, event_date: @date).exists?,
           "Project two should have DAU rows"
  end

  test "DAU counts are scoped per project not global" do
    # Ensure a second project's visitors don't inflate project one's count
    project_two = projects(:two)
    device_two = create_device("ios")
    visitor_two = Visitor.create!(project: project_two, device: device_two, web_visitor: false)
    create_stat(visitor_two, project_two, @date, "ios", views: 1)

    ProjectDailyActiveUsersGenerator.call(@date)

    # Project one should still have 1 iOS visitor, not 2
    assert_equal 1, find_dau(@project, @date, "ios").active_users,
                 "Project two's visitor should not count toward project one's DAU"
    assert_equal 1, find_dau(project_two, @date, "ios").active_users
  end

  # ---------------------------------------------------------------------------
  # Edge cases
  # ---------------------------------------------------------------------------

  test "no visitor stats for a date produces zero DAU rows" do
    empty_date = Date.new(2026, 6, 1)

    ProjectDailyActiveUsersGenerator.call(empty_date)

    assert_equal 0, ProjectDailyActiveUser.where(event_date: empty_date).count,
                 "No stats -> no DAU rows (should not insert zero-count rows)"
  end

  test "different dates produce independent rows" do
    day1 = Date.new(2026, 3, 1)
    day2 = Date.new(2026, 3, 2)

    ProjectDailyActiveUsersGenerator.call(day1)
    ProjectDailyActiveUsersGenerator.call(day2)

    # Day 1: ios + android (from fixtures)
    assert_equal 2, ProjectDailyActiveUser.where(project_id: @project.id, event_date: day1).count

    # Day 2: only ios (ios_stat_day2 fixture, no android_stat_day2)
    day2_ios = find_dau(@project, day2, "ios")
    assert_not_nil day2_ios
    assert_equal 1, day2_ios.active_users
    assert_nil find_dau(@project, day2, "android"),
               "No android stats on day 2, so no DAU row should exist"
  end

  test "lock_timeout failure rolls back cleanly leaving previous data intact" do
    ProjectDailyActiveUsersGenerator.call(@date)
    before_count = ProjectDailyActiveUser.where(event_date: @date).count
    before_snapshot = dau_snapshot(@date)
    assert_equal 2, before_count, "Precondition: day1 has ios + android = 2 DAU rows"

    # Stub execute to raise on ALL shard INSERTs (not just the first).
    # This ensures we're testing rollback, not "other shards re-wrote the same data."
    conn = ActiveRecord::Base.connection
    original_execute = conn.method(:execute)

    conn.stub(:execute, lambda { |sql, *args|
      if sql.include?("INSERT INTO project_daily_active_users")
        raise ActiveRecord::StatementInvalid,
              "PG::QueryCanceled: ERROR: canceling statement due to lock timeout"
      end
      original_execute.call(sql, *args)
    }) do
      assert_raises(ActiveRecord::StatementInvalid) do
        ProjectDailyActiveUsersGenerator.call(@date)
      end
    end

    # Data from first successful run should still be intact
    after_count = ProjectDailyActiveUser.where(event_date: @date).count
    after_snapshot = dau_snapshot(@date)

    assert_equal before_count, after_count,
                 "Failed transaction should roll back, leaving previous data intact"
    assert_equal before_snapshot, after_snapshot,
                 "Values should be identical, not just count"
  end

  private

  def find_dau(project, date, platform)
    ProjectDailyActiveUser.find_by(project_id: project.id, event_date: date, platform: platform)
  end

  def dau_snapshot(date)
    ProjectDailyActiveUser.where(event_date: date)
                          .pluck(:project_id, :platform, :active_users)
                          .sort
  end

  def create_device(platform)
    Device.create!(
      platform: platform,
      user_agent: "Test/#{SecureRandom.hex(2)}",
      ip: "#{rand(1..254)}.#{rand(1..254)}.#{rand(1..254)}.#{rand(1..254)}",
      remote_ip: "#{rand(1..254)}.#{rand(1..254)}.#{rand(1..254)}.#{rand(1..254)}"
    )
  end

  def create_stat(visitor, project, date, platform, metrics = {})
    VisitorDailyStatistic.create!(
      visitor: visitor,
      project_id: project.id,
      event_date: date,
      platform: platform,
      views: metrics[:views] || 0,
      opens: metrics[:opens] || 0,
      installs: 0, reinstalls: 0, time_spent: 0,
      revenue: 0, reactivations: 0, app_opens: 0, user_referred: 0
    )
  end
end
