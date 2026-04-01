require "test_helper"

class TopLinksAnalyticsTest < ActiveSupport::TestCase
  fixtures :projects, :instances, :domains, :links, :redirect_configs

  setup do
    @project = projects(:one)
    @pid = @project.id
    @basic_link = links(:basic_link)

    # Clean existing stats and create controlled data
    LinkDailyStatistic.where(project_id: @pid).delete_all

    # basic_link: ios stats on day 1 and day 2
    # Day 1: 100 views, 50 opens, 10 installs
    LinkDailyStatistic.insert_all([{
      link_id: @basic_link.id, project_id: @pid,
      event_date: Date.new(2026, 3, 1), platform: "ios",
      views: 100, opens: 50, installs: 10, reinstalls: 2,
      time_spent: 5000, reactivations: 1, app_opens: 30,
      user_referred: 3, revenue: 999,
      created_at: Time.current, updated_at: Time.current
    }])
    # Day 2: 200 views, 80 opens, 20 installs
    LinkDailyStatistic.insert_all([{
      link_id: @basic_link.id, project_id: @pid,
      event_date: Date.new(2026, 3, 2), platform: "ios",
      views: 200, opens: 80, installs: 20, reinstalls: 5,
      time_spent: 8000, reactivations: 3, app_opens: 60,
      user_referred: 7, revenue: 1999,
      created_at: Time.current, updated_at: Time.current
    }])

    # Create a second non-SDK link in project one's domain for ranking tests
    @second_project_link = Link.create!(
      domain: domains(:one), redirect_config: redirect_configs(:one),
      path: "second-proj-link-#{SecureRandom.hex(4)}", active: true,
      sdk_generated: false, data: "[]", generated_from_platform: "android"
    )
    # Day 1: android stats, fewer installs than basic_link
    LinkDailyStatistic.insert_all([{
      link_id: @second_project_link.id, project_id: @pid,
      event_date: Date.new(2026, 3, 1), platform: "android",
      views: 50, opens: 25, installs: 5, reinstalls: 1,
      time_spent: 2000, reactivations: 0, app_opens: 15,
      user_referred: 1, revenue: 499,
      created_at: Time.current, updated_at: Time.current
    }])
  end

  # --- Sorting ---

  test "returns top links sorted by installs descending" do
    result = TopLinksAnalytics.new(
      project_id: @pid, platform: nil,
      start_time: "2026-03-01", end_time: "2026-03-02"
    ).call

    assert_equal 2, result.size

    installs = result.map { |r| r[:installs] }
    assert_equal installs, installs.sort.reverse, "Expected descending order by installs"

    # basic_link has 30 total installs; second has 5
    assert_equal 30, result.first[:installs]
    assert_equal 5, result.last[:installs]
  end

  # --- Link data merged with stats ---

  test "includes link fields and exact stat values" do
    result = TopLinksAnalytics.new(
      project_id: @pid, platform: nil,
      start_time: "2026-03-01", end_time: "2026-03-02"
    ).call

    entry = result.find { |r| r["id"] == @basic_link.id }
    assert_not_nil entry, "Expected basic_link in results"

    # Verify stat aggregation (day 1 + day 2)
    assert_equal 300, entry[:views], "100 + 200 = 300 views"
    assert_equal 130, entry[:opens], "50 + 80 = 130 opens"
    assert_equal 30, entry[:installs], "10 + 20 = 30 installs"
    assert_equal 7, entry[:reinstalls], "2 + 5 = 7 reinstalls"
    assert_equal 4, entry[:reactivations], "1 + 3 = 4 reactivations"
    assert_equal 13000, entry[:time_spent], "5000 + 8000 = 13000 time_spent"

    # Verify link attributes from as_json are present
    assert_equal @basic_link.id, entry["id"]
    assert_equal "test-path", entry["path"]
    assert_equal "Test Link", entry["title"]
  end

  # --- Limit ---

  test "respects limit parameter" do
    result = TopLinksAnalytics.new(
      project_id: @pid, platform: nil,
      start_time: "2026-03-01", end_time: "2026-03-02",
      limit: 1
    ).call

    assert_equal 1, result.size
    # Should be the top link by installs (basic_link with 30)
    assert_equal 30, result.first[:installs]
  end

  # --- SDK exclusion ---

  test "excludes sdk_generated links" do
    sdk_link = Link.create!(
      domain: domains(:one), redirect_config: redirect_configs(:one),
      path: "sdk-link-#{SecureRandom.hex(4)}", active: true, sdk_generated: true, data: "[]",
      generated_from_platform: "ios"
    )
    LinkDailyStatistic.insert_all([{
      link_id: sdk_link.id, project_id: @pid,
      event_date: Date.new(2026, 3, 1), platform: "ios",
      views: 9999, opens: 9999, installs: 9999, reinstalls: 0,
      time_spent: 0, reactivations: 0, app_opens: 0, user_referred: 0, revenue: 0,
      created_at: Time.current, updated_at: Time.current
    }])

    result = TopLinksAnalytics.new(
      project_id: @pid, platform: nil,
      start_time: "2026-03-01", end_time: "2026-03-02"
    ).call

    link_ids = result.map { |r| r["id"] }
    assert_not_includes link_ids, sdk_link.id, "SDK-generated links must be excluded"
  end

  # --- Platform filter ---

  test "platform filter returns only stats for the specified platform" do
    ios_result = TopLinksAnalytics.new(
      project_id: @pid, platform: "ios",
      start_time: "2026-03-01", end_time: "2026-03-02"
    ).call

    # Only basic_link has ios stats
    assert_equal 1, ios_result.size, "Only basic_link has ios stats"
    assert_equal @basic_link.id, ios_result.first["id"]
    assert_equal 30, ios_result.first[:installs], "ios installs: 10 + 20 = 30"
    assert_equal 300, ios_result.first[:views], "ios views: 100 + 200 = 300"
  end

  test "platform filter android returns only android stats" do
    android_result = TopLinksAnalytics.new(
      project_id: @pid, platform: "android",
      start_time: "2026-03-01", end_time: "2026-03-02"
    ).call

    # Only second_project_link has android stats
    assert_equal 1, android_result.size, "Only second_project_link has android stats"
    assert_equal @second_project_link.id, android_result.first["id"]
    assert_equal 5, android_result.first[:installs]
    assert_equal 50, android_result.first[:views]
  end

  test "platform filter for nonexistent platform returns empty" do
    result = TopLinksAnalytics.new(
      project_id: @pid, platform: "desktop",
      start_time: "2026-03-01", end_time: "2026-03-02"
    ).call

    assert_equal [], result
  end

  # --- Empty results ---

  test "returns empty array for project with no links" do
    result = TopLinksAnalytics.new(
      project_id: projects(:two).id, platform: nil,
      start_time: "2026-03-01", end_time: "2026-03-02"
    ).call

    assert_equal [], result
  end

  test "returns empty array for date range with no stats" do
    result = TopLinksAnalytics.new(
      project_id: @pid, platform: nil,
      start_time: "2020-01-01", end_time: "2020-01-02"
    ).call

    assert_equal [], result
  end

  # --- Single day range ---

  test "single day range returns only that day stats" do
    result = TopLinksAnalytics.new(
      project_id: @pid, platform: nil,
      start_time: "2026-03-01", end_time: "2026-03-01"
    ).call

    basic_entry = result.find { |r| r["id"] == @basic_link.id }
    assert_not_nil basic_entry

    # Only day 1 stats for basic_link
    assert_equal 100, basic_entry[:views]
    assert_equal 50, basic_entry[:opens]
    assert_equal 10, basic_entry[:installs]
  end
end
