require "test_helper"

class VisitorReferralStatisticsQueryTest < ActiveSupport::TestCase
  fixtures :visitors, :visitor_daily_statistics, :projects, :devices, :instances,
          :events, :links, :domains, :redirect_configs

  setup do
    @project = projects(:one)
    @ios_visitor = visitors(:ios_visitor)
    @android_visitor = visitors(:android_visitor)
    @base_params = {
      start_date: Date.parse("2026-03-01"),
      end_date: Date.parse("2026-03-02"),
      page: 1,
      per_page: 20
    }

    # Clear fixture data and create controlled test data so counts/sort
    # don't break when someone adds a new fixture
    VisitorDailyStatistic.where(project_id: @project.id).delete_all
    Event.where(project: @project).delete_all

    # ios_visitor's own stats
    VisitorDailyStatistic.create!(visitor: @ios_visitor, project_id: @project.id,
      event_date: "2026-03-01", platform: "ios",
      views: 50, opens: 20, installs: 5, reinstalls: 1,
      time_spent: 3000, revenue: 500, reactivations: 0, app_opens: 10, user_referred: 2)
    VisitorDailyStatistic.create!(visitor: @ios_visitor, project_id: @project.id,
      event_date: "2026-03-02", platform: "ios",
      views: 80, opens: 30, installs: 8, reinstalls: 2,
      time_spent: 5000, revenue: 800, reactivations: 1, app_opens: 20, user_referred: 4)
    # android_visitor's stat — invited by ios_visitor (referral relationship)
    VisitorDailyStatistic.create!(visitor: @android_visitor, project_id: @project.id,
      event_date: "2026-03-01", platform: "android", invited_by_id: @ios_visitor.id,
      views: 30, opens: 10, installs: 3, reinstalls: 0,
      time_spent: 2000, revenue: 300, reactivations: 0, app_opens: 8, user_referred: 1)
  end

  # === Basic query execution ===

  test "call returns visitors with invited_ metrics and pagination meta" do
    result = query(@base_params).call

    assert result.key?(:visitors)
    assert result.key?(:meta)
    assert_equal 1, result[:meta][:page]
    assert_equal 1, result[:meta][:total_entries], "Only ios_visitor is an inviter"
  end

  test "call returns correct invited totals for the inviter" do
    result = query(@base_params).call
    ios_row = result[:visitors].find { |v| v["id"] == @ios_visitor.id }

    assert_not_nil ios_row, "ios_visitor (the inviter) should be in results"
    # android_stat_day1 has invited_by_id = ios_visitor.id
    # views=30, opens=10, installs=3, time_spent=2000, revenue=300
    assert_equal 30, ios_row["invited_views"].to_i
    assert_equal 10, ios_row["invited_opens"].to_i
    assert_equal 3, ios_row["invited_installs"].to_i
    assert_equal 2000, ios_row["invited_time_spent"].to_i
    assert_equal 300, ios_row["invited_revenue"].to_i
    assert_equal 1, ios_row["invited_user_referred"].to_i
  end

  test "call returns zero invited metrics for visitors who referred nobody" do
    # Create a stat where android_visitor is the inviter but all metrics are zero.
    # Use a unique date (2026-03-05) to avoid colliding with fixture data.
    VisitorDailyStatistic.create!(
      visitor: @ios_visitor,
      project_id: @project.id,
      event_date: Date.parse("2026-03-05"),
      platform: "ios",
      invited_by_id: @android_visitor.id,
      views: 0, opens: 0, installs: 0, reinstalls: 0,
      time_spent: 0, revenue: 0, reactivations: 0, app_opens: 0, user_referred: 0
    )

    params = @base_params.merge(
      start_date: Date.parse("2026-03-05"),
      end_date: Date.parse("2026-03-05")
    )
    result = query(params).call
    android_row = result[:visitors].find { |v| v["id"] == @android_visitor.id }

    assert_not_nil android_row
    # Use explicit type check — nil.to_i would also be 0, masking a COALESCE bug
    assert_equal 0, android_row["invited_views"], "Expected Integer 0, not nil"
    assert_equal 0, android_row["invited_revenue"], "Expected Integer 0, not nil"
  end

  # === Date filtering ===

  test "call filters by date range — excludes stats outside range" do
    params = @base_params.merge(
      start_date: Date.parse("2025-01-01"),
      end_date: Date.parse("2025-01-02")
    )
    result = query(params).call
    assert_equal 0, result[:meta][:total_entries]
  end

  test "call single day returns only that day's invited stats" do
    params = @base_params.merge(
      start_date: Date.parse("2026-03-01"),
      end_date: Date.parse("2026-03-01")
    )
    result = query(params).call
    ios_row = result[:visitors].find { |v| v["id"] == @ios_visitor.id }

    assert_not_nil ios_row
    # Only android_stat_day1 (the one with invited_by_id = ios_visitor)
    assert_equal 30, ios_row["invited_views"].to_i
  end

  # === Project scoping ===

  test "call scopes to project — other project returns nothing" do
    other_project = projects(:two)
    result = query(@base_params, project: other_project).call
    assert_equal 0, result[:meta][:total_entries]
  end

  # === Visitor ID filter ===

  test "call filters by visitor_id" do
    params = @base_params.merge(visitor_id: @ios_visitor.id)
    result = query(params).call

    assert_equal 1, result[:meta][:total_entries]
    assert_equal @ios_visitor.id, result[:visitors].first["id"]
  end

  # === Search (term) ===

  test "call filters by sdk_identifier search term" do
    @ios_visitor.update_columns(sdk_identifier: "referral-sdk-unique-xyz")
    params = @base_params.merge(term: "referral-sdk-unique")
    result = query(params).call

    assert_equal 1, result[:meta][:total_entries]
    assert_equal @ios_visitor.id, result[:visitors].first["id"]
  end

  test "call filters by uuid search term" do
    uuid_fragment = @ios_visitor.uuid.to_s[0..7]
    params = @base_params.merge(term: uuid_fragment)
    result = query(params).call

    ids = result[:visitors].map { |v| v["id"] }
    assert_includes ids, @ios_visitor.id
  end

  test "call returns nothing for non-matching search term" do
    params = @base_params.merge(term: "zzz-no-match-zzz-9999")
    result = query(params).call
    assert_equal 0, result[:meta][:total_entries]
  end

  # === Platform filter ===

  test "call filters by platform" do
    params = @base_params.merge(platform: "ios")
    result = query(params).call

    # ios_visitor has device platform=ios and has referral stats
    ids = result[:visitors].map { |v| v["id"] }
    assert_includes ids, @ios_visitor.id
  end

  test "call platform filter is case-insensitive" do
    params = @base_params.merge(platform: "IOS")
    result = query(params).call

    ids = result[:visitors].map { |v| v["id"] }
    assert_includes ids, @ios_visitor.id
  end

  test "call returns nothing for non-existent platform" do
    params = @base_params.merge(platform: "blackberry")
    result = query(params).call
    assert_equal 0, result[:meta][:total_entries]
  end

  # === Sorting by visitor fields ===

  test "call sorts by created_at descending" do
    # Give visitors distinct timestamps so sort order is deterministic
    @ios_visitor.update_columns(created_at: 2.days.ago)
    @android_visitor.update_columns(created_at: 1.day.ago)
    # android_visitor also needs a referral stat pointing to it so it appears
    VisitorDailyStatistic.create!(
      visitor: @ios_visitor,
      project_id: @project.id,
      event_date: Date.parse("2026-03-05"),
      platform: "ios",
      invited_by_id: @android_visitor.id,
      views: 1, opens: 0, installs: 0, reinstalls: 0,
      time_spent: 0, revenue: 0, reactivations: 0, app_opens: 0, user_referred: 0
    )

    params = @base_params.merge(
      start_date: Date.parse("2026-03-01"),
      end_date: Date.parse("2026-03-05"),
      sort_by: "created_at", ascendent: false
    )
    result = query(params).call

    ids = result[:visitors].map { |v| v["id"] }
    assert_equal [@android_visitor.id, @ios_visitor.id], ids
  end

  test "call sorts by created_at ascending" do
    @ios_visitor.update_columns(created_at: 2.days.ago)
    @android_visitor.update_columns(created_at: 1.day.ago)
    VisitorDailyStatistic.create!(
      visitor: @ios_visitor,
      project_id: @project.id,
      event_date: Date.parse("2026-03-05"),
      platform: "ios",
      invited_by_id: @android_visitor.id,
      views: 1, opens: 0, installs: 0, reinstalls: 0,
      time_spent: 0, revenue: 0, reactivations: 0, app_opens: 0, user_referred: 0
    )

    params = @base_params.merge(
      start_date: Date.parse("2026-03-01"),
      end_date: Date.parse("2026-03-05"),
      sort_by: "created_at", ascendent: true
    )
    result = query(params).call

    ids = result[:visitors].map { |v| v["id"] }
    assert_equal [@ios_visitor.id, @android_visitor.id], ids
  end

  # === Sorting by metric fields ===

  test "call sorts by views descending" do
    # Create a referral stat on a non-colliding date where android_visitor is the inviter
    # with high views, so we get two inviters with different totals.
    VisitorDailyStatistic.create!(
      visitor: @ios_visitor,
      project_id: @project.id,
      event_date: Date.parse("2026-03-10"),
      platform: "ios",
      invited_by_id: @android_visitor.id,
      views: 999, opens: 0, installs: 0, reinstalls: 0,
      time_spent: 0, revenue: 0, reactivations: 0, app_opens: 0, user_referred: 0
    )

    params = @base_params.merge(
      start_date: Date.parse("2026-03-01"),
      end_date: Date.parse("2026-03-10"),
      sort_by: "views", ascendent: false
    )
    result = query(params).call

    totals = result[:visitors].map { |v| v["invited_views"].to_i }
    assert_equal totals, totals.sort.reverse
  end

  test "call sorts by revenue ascending" do
    VisitorDailyStatistic.create!(
      visitor: @ios_visitor,
      project_id: @project.id,
      event_date: Date.parse("2026-03-10"),
      platform: "ios",
      invited_by_id: @android_visitor.id,
      views: 0, opens: 0, installs: 0, reinstalls: 0,
      time_spent: 0, revenue: 5000, reactivations: 0, app_opens: 0, user_referred: 0
    )

    params = @base_params.merge(
      start_date: Date.parse("2026-03-01"),
      end_date: Date.parse("2026-03-10"),
      sort_by: "revenue", ascendent: true
    )
    result = query(params).call

    totals = result[:visitors].map { |v| v["invited_revenue"].to_i }
    assert_equal totals, totals.sort
  end

  # === Default sort (invalid sort_by) ===

  test "call defaults to created_at DESC for invalid sort_by" do
    @ios_visitor.update_columns(created_at: 2.days.ago)
    @android_visitor.update_columns(created_at: 1.day.ago)
    VisitorDailyStatistic.create!(
      visitor: @ios_visitor,
      project_id: @project.id,
      event_date: Date.parse("2026-03-06"),
      platform: "ios",
      invited_by_id: @android_visitor.id,
      views: 1, opens: 0, installs: 0, reinstalls: 0,
      time_spent: 0, revenue: 0, reactivations: 0, app_opens: 0, user_referred: 0
    )

    params = @base_params.merge(
      start_date: Date.parse("2026-03-01"),
      end_date: Date.parse("2026-03-06"),
      sort_by: "definitely_not_valid"
    )
    result = query(params).call

    ids = result[:visitors].map { |v| v["id"] }
    # Default is created_at DESC, so android (newer) should come first
    assert_equal [@android_visitor.id, @ios_visitor.id], ids
  end

  # === Pagination ===

  test "call paginates correctly" do
    # Need at least 2 inviters for pagination test.
    # Use a non-colliding date so the unique constraint is satisfied.
    VisitorDailyStatistic.create!(
      visitor: @ios_visitor,
      project_id: @project.id,
      event_date: Date.parse("2026-03-11"),
      platform: "ios",
      invited_by_id: @android_visitor.id,
      views: 5, opens: 0, installs: 0, reinstalls: 0,
      time_spent: 0, revenue: 0, reactivations: 0, app_opens: 0, user_referred: 0
    )

    params_p1 = @base_params.merge(
      start_date: Date.parse("2026-03-01"),
      end_date: Date.parse("2026-03-11"),
      per_page: 1, page: 1
    )
    result = query(params_p1).call

    assert_equal 1, result[:visitors].size
    assert_equal 2, result[:meta][:total_pages], "2 inviters / per_page=1 = 2 pages"
  end

  # === All metric columns present ===

  test "call returns all metric columns as invited_ prefixed" do
    result = query(@base_params).call
    row = result[:visitors].first

    VisitorDailyStatistic::METRIC_COLUMNS.each do |col|
      assert row.key?("invited_#{col}"), "Expected invited_#{col} in result, got keys: #{row.keys}"
    end
  end

  # === COALESCE behavior (LEFT JOIN nulls) ===

  test "call uses COALESCE so NULL sums become zero not nil" do
    # Create a fresh visitor and a referral stat with all zeros pointing to it.
    # Uses a non-colliding date + platform to avoid unique constraint violations.
    new_device = Device.create!(user_agent: "Test/1.0", ip: "1.2.3.4", remote_ip: "5.6.7.8", platform: "web")
    new_visitor = Visitor.create!(project: @project, device: new_device, web_visitor: true)

    VisitorDailyStatistic.create!(
      visitor: @android_visitor,
      project_id: @project.id,
      event_date: Date.parse("2026-03-12"),
      platform: "android",
      invited_by_id: new_visitor.id,
      views: 0, opens: 0, installs: 0, reinstalls: 0,
      time_spent: 0, revenue: 0, reactivations: 0, app_opens: 0, user_referred: 0
    )

    params = @base_params.merge(
      start_date: Date.parse("2026-03-12"),
      end_date: Date.parse("2026-03-12"),
      visitor_id: new_visitor.id
    )
    result = query(params).call

    assert_equal 1, result[:meta][:total_entries]
    row = result[:visitors].first
    VisitorDailyStatistic::METRIC_COLUMNS.each do |col|
      value = row["invited_#{col}"]
      assert_not_nil value, "invited_#{col} should be 0 via COALESCE, not nil"
      assert_equal 0, value, "Expected invited_#{col} to be 0"
    end
  end

  # === Legacy paginated_aggregated_events (OLD API) ===

  test "paginated_aggregated_events counts events through visitor-owned links" do
    # Set up: ios_visitor owns a link, and events are attached to that link
    link = links(:basic_link)
    link.update_columns(visitor_id: @ios_visitor.id)
    Event.create!(
      project: @project, device: devices(:android_device), link: link,
      event: "view", engagement_time: 4000, platform: "android"
    )
    Event.create!(
      project: @project, device: devices(:android_device), link: link,
      event: "open", engagement_time: 1500, platform: "android"
    )

    result = VisitorReferralStatisticsQuery.paginated_aggregated_events(
      page: 1, event_type: "created_at", asc: false, project: @project,
      start_date: 1.year.ago, end_date: Date.tomorrow
    )

    ios_row = result[:metrics].to_a.find { |r| r["id"] == @ios_visitor.id }
    assert_not_nil ios_row
    assert_equal 1, ios_row["view_count"].to_i
    assert_equal 4000, ios_row["view_engagement_time"].to_i
    assert_equal 1, ios_row["open_count"].to_i
    assert_equal 1500, ios_row["open_engagement_time"].to_i
    assert_equal 0, ios_row["install_count"].to_i, "No install events through links"
  end

  test "paginated_aggregated_events excludes events from other projects" do
    other_project = projects(:two)
    link = links(:basic_link)
    link.update_columns(visitor_id: @ios_visitor.id)

    # Event on THIS project — should be counted
    Event.create!(
      project: @project, device: devices(:android_device), link: link,
      event: "view", engagement_time: 1000, platform: "android"
    )
    # Event on OTHER project — should NOT be counted
    Event.create!(
      project: other_project, device: devices(:android_device), link: link,
      event: "view", engagement_time: 9999, platform: "android"
    )

    result = VisitorReferralStatisticsQuery.paginated_aggregated_events(
      page: 1, event_type: "created_at", asc: false, project: @project,
      start_date: 1.year.ago, end_date: Date.tomorrow
    )

    ios_row = result[:metrics].to_a.find { |r| r["id"] == @ios_visitor.id }
    assert_equal 1, ios_row["view_count"].to_i, "Should only count this project's events"
    assert_equal 1000, ios_row["view_engagement_time"].to_i, "Should not include other project's 9999"
  end

  test "paginated_aggregated_events returns zero counts for visitors with no referral events" do
    result = VisitorReferralStatisticsQuery.paginated_aggregated_events(
      page: 1, event_type: "created_at", asc: false, project: @project,
      start_date: 1.year.ago, end_date: Date.tomorrow
    )

    assert result.key?(:metrics)
    result[:metrics].to_a.each do |row|
      Grovs::Events::ALL.each do |et|
        assert_equal 0, row["#{et}_count"].to_i, "Expected #{et}_count to be 0 for visitor #{row['id']}"
      end
    end
  end

  test "paginated_aggregated_events sorts by created_at ascending and descending" do
    @ios_visitor.update_columns(created_at: 2.days.ago, updated_at: Time.current)
    @android_visitor.update_columns(created_at: 1.day.ago, updated_at: Time.current)

    asc_result = VisitorReferralStatisticsQuery.paginated_aggregated_events(
      page: 1, event_type: "created_at", asc: true, project: @project,
      start_date: 1.year.ago, end_date: Date.tomorrow
    )
    desc_result = VisitorReferralStatisticsQuery.paginated_aggregated_events(
      page: 1, event_type: "created_at", asc: false, project: @project,
      start_date: 1.year.ago, end_date: Date.tomorrow
    )

    asc_ids = asc_result[:metrics].to_a.map { |r| r["id"] }
    desc_ids = desc_result[:metrics].to_a.map { |r| r["id"] }

    assert_equal asc_ids.reverse, desc_ids, "ASC and DESC should produce opposite ordering"
    assert_equal @ios_visitor.id, asc_ids.first, "Older visitor should be first in ASC"
    assert_equal @android_visitor.id, desc_ids.first, "Newer visitor should be first in DESC"
  end

  test "paginated_aggregated_events filters by updated_at date range" do
    @ios_visitor.update_columns(updated_at: Date.parse("2026-03-01").noon)
    @android_visitor.update_columns(updated_at: Date.parse("2026-06-01").noon)

    result = VisitorReferralStatisticsQuery.paginated_aggregated_events(
      page: 1, event_type: "created_at", asc: false, project: @project,
      start_date: Date.parse("2026-03-01"), end_date: Date.parse("2026-03-02")
    )

    ids = result[:metrics].to_a.map { |r| r["id"] }
    assert_includes ids, @ios_visitor.id, "Visitor within date range should be included"
    assert_not_includes ids, @android_visitor.id, "Visitor outside date range should be excluded"
  end

  test "paginated_aggregated_events filters by search term" do
    @ios_visitor.update_columns(sdk_identifier: "referral-legacy-unique-abc")

    result = VisitorReferralStatisticsQuery.paginated_aggregated_events(
      page: 1, event_type: "created_at", asc: false, project: @project,
      start_date: 1.year.ago, end_date: Date.tomorrow,
      term: "referral-legacy-unique"
    )

    assert_equal 1, result[:total_entries]
  end

  test "paginated_aggregated_events paginates correctly" do
    result = VisitorReferralStatisticsQuery.paginated_aggregated_events(
      page: 1, event_type: "created_at", asc: false, project: @project,
      start_date: 1.year.ago, end_date: Date.tomorrow,
      per_page: 1
    )

    assert_equal 1, result[:metrics].to_a.size
    assert_equal 2, result[:total_pages], "2 visitors / per_page=1 = 2 pages"
  end

  private

  def query(params, project: @project)
    VisitorReferralStatisticsQuery.new(params: params, project: project)
  end
end
