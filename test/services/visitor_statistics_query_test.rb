require "test_helper"

class VisitorStatisticsQueryTest < ActiveSupport::TestCase
  fixtures :visitors, :visitor_daily_statistics, :projects, :devices, :instances, :events

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

    # 3 VDS records: ios day1+day2, android day1
    VisitorDailyStatistic.create!(visitor: @ios_visitor, project_id: @project.id,
      event_date: "2026-03-01", platform: "ios",
      views: 50, opens: 20, installs: 5, reinstalls: 1,
      time_spent: 3000, revenue: 500, reactivations: 0, app_opens: 10, user_referred: 2)
    VisitorDailyStatistic.create!(visitor: @ios_visitor, project_id: @project.id,
      event_date: "2026-03-02", platform: "ios",
      views: 80, opens: 30, installs: 8, reinstalls: 2,
      time_spent: 5000, revenue: 800, reactivations: 1, app_opens: 20, user_referred: 4)
    VisitorDailyStatistic.create!(visitor: @android_visitor, project_id: @project.id,
      event_date: "2026-03-01", platform: "android",
      views: 30, opens: 10, installs: 3, reinstalls: 0,
      time_spent: 2000, revenue: 300, reactivations: 0, app_opens: 8, user_referred: 1)

    # Events for paginated_own_events tests
    # ios_device: view(5000), open(3000), install(0)
    Event.create!(project: @project, device: devices(:ios_device),
      event: "view", platform: "ios", engagement_time: 5000)
    Event.create!(project: @project, device: devices(:ios_device),
      event: "open", platform: "ios", engagement_time: 3000)
    Event.create!(project: @project, device: devices(:ios_device),
      event: "install", platform: "ios", engagement_time: 0)
    # android_device: view(2000), reinstall(0)
    Event.create!(project: @project, device: devices(:android_device),
      event: "view", platform: "android", engagement_time: 2000)
    Event.create!(project: @project, device: devices(:android_device),
      event: "reinstall", platform: "android", engagement_time: 0)
  end

  # === Basic query execution ===

  test "call returns visitors with aggregated metrics and pagination meta" do
    result = query(@base_params).call

    assert result.key?(:visitors)
    assert result.key?(:meta)
    assert_equal 1, result[:meta][:page]
    assert_equal 2, result[:meta][:total_entries], "Should return both ios and android visitors"
  end

  test "call returns correct aggregated totals for ios_visitor" do
    result = query(@base_params).call
    ios_row = result[:visitors].find { |v| v["id"] == @ios_visitor.id }

    assert_not_nil ios_row, "ios_visitor should be in results"
    # ios_stat_day1(50) + ios_stat_day2(80) = 130
    assert_equal 130, ios_row["total_views"].to_i
    # ios_stat_day1(20) + ios_stat_day2(30) = 50
    assert_equal 50, ios_row["total_opens"].to_i
    # ios_stat_day1(5) + ios_stat_day2(8) = 13
    assert_equal 13, ios_row["total_installs"].to_i
    # ios_stat_day1(3000) + ios_stat_day2(5000) = 8000
    assert_equal 8000, ios_row["total_time_spent"].to_i
    # ios_stat_day1(500) + ios_stat_day2(800) = 1300
    assert_equal 1300, ios_row["total_revenue"].to_i
  end

  test "call returns correct aggregated totals for android_visitor" do
    result = query(@base_params).call
    android_row = result[:visitors].find { |v| v["id"] == @android_visitor.id }

    assert_not_nil android_row, "android_visitor should be in results"
    # android_stat_day1 only: views=30, opens=10, installs=3
    assert_equal 30, android_row["total_views"].to_i
    assert_equal 10, android_row["total_opens"].to_i
    assert_equal 3, android_row["total_installs"].to_i
    assert_equal 2000, android_row["total_time_spent"].to_i
    assert_equal 300, android_row["total_revenue"].to_i
  end

  test "call includes platform from device" do
    result = query(@base_params).call
    ios_row = result[:visitors].find { |v| v["id"] == @ios_visitor.id }
    assert_equal "ios", ios_row["platform"]
  end

  # === Date filtering ===

  test "call filters by date range — single day excludes other days" do
    params = @base_params.merge(start_date: Date.parse("2026-03-01"), end_date: Date.parse("2026-03-01"))
    result = query(params).call

    ios_row = result[:visitors].find { |v| v["id"] == @ios_visitor.id }
    assert_not_nil ios_row
    # Only day1: views=50
    assert_equal 50, ios_row["total_views"].to_i
  end

  test "call returns empty for date range with no data" do
    params = @base_params.merge(start_date: Date.parse("2025-01-01"), end_date: Date.parse("2025-01-02"))
    result = query(params).call
    assert_equal 0, result[:meta][:total_entries]
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
    @ios_visitor.update_columns(sdk_identifier: "unique-sdk-search-test")
    params = @base_params.merge(term: "unique-sdk-search")
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

    assert_equal 1, result[:meta][:total_entries], "Only ios_visitor has an ios device"
    result[:visitors].each do |v|
      assert_equal "ios", v["platform"]
    end
  end

  test "call platform filter is case-insensitive" do
    params = @base_params.merge(platform: "IOS")
    result = query(params).call

    assert_equal 1, result[:meta][:total_entries], "Only ios_visitor has an ios device"
    result[:visitors].each do |v|
      assert_equal "ios", v["platform"]
    end
  end

  test "call returns nothing for non-existent platform" do
    params = @base_params.merge(platform: "blackberry")
    result = query(params).call
    assert_equal 0, result[:meta][:total_entries]
  end

  # === Sorting by visitor fields ===

  test "call sorts by created_at ascending" do
    # Give the visitors distinct created_at values so the sort is testable
    @ios_visitor.update_columns(created_at: 2.days.ago)
    @android_visitor.update_columns(created_at: 1.day.ago)

    params = @base_params.merge(sort_by: "created_at", ascendent: true)
    result = query(params).call

    ids = result[:visitors].map { |v| v["id"] }
    assert_equal [@ios_visitor.id, @android_visitor.id], ids
  end

  test "call sorts by created_at descending" do
    @ios_visitor.update_columns(created_at: 2.days.ago)
    @android_visitor.update_columns(created_at: 1.day.ago)

    params = @base_params.merge(sort_by: "created_at", ascendent: false)
    result = query(params).call

    ids = result[:visitors].map { |v| v["id"] }
    assert_equal [@android_visitor.id, @ios_visitor.id], ids
  end

  # === Sorting by metric fields ===

  test "call sorts by views descending" do
    params = @base_params.merge(sort_by: "views", ascendent: false)
    result = query(params).call

    totals = result[:visitors].map { |v| v["total_views"].to_i }
    assert_equal totals, totals.sort.reverse
  end

  test "call sorts by views ascending" do
    params = @base_params.merge(sort_by: "views", ascendent: true)
    result = query(params).call

    totals = result[:visitors].map { |v| v["total_views"].to_i }
    assert_equal totals, totals.sort
  end

  test "call sorts by revenue descending" do
    params = @base_params.merge(sort_by: "revenue", ascendent: false)
    result = query(params).call

    totals = result[:visitors].map { |v| v["total_revenue"].to_i }
    assert_equal totals, totals.sort.reverse
  end

  test "call sorts by time_spent ascending" do
    params = @base_params.merge(sort_by: "time_spent", ascendent: true)
    result = query(params).call

    totals = result[:visitors].map { |v| v["total_time_spent"].to_i }
    assert_equal totals, totals.sort
  end

  # === Default sort (invalid sort_by) ===

  test "call defaults to created_at DESC for invalid sort_by" do
    @ios_visitor.update_columns(created_at: 2.days.ago)
    @android_visitor.update_columns(created_at: 1.day.ago)

    params = @base_params.merge(sort_by: "definitely_not_valid")
    result = query(params).call

    ids = result[:visitors].map { |v| v["id"] }
    # Default is created_at DESC, so android (newer) should come first
    assert_equal [@android_visitor.id, @ios_visitor.id], ids
  end

  # === Pagination ===

  test "call paginates with per_page=1" do
    params = @base_params.merge(per_page: 1, page: 1)
    result = query(params).call

    assert_equal 1, result[:visitors].size
    assert_equal 2, result[:meta][:total_pages], "2 visitors / per_page=1 = 2 pages"
    assert_equal 1, result[:meta][:per_page]
  end

  test "call page 2 returns different results than page 1" do
    # Set distinct created_at so default sort order is deterministic
    @ios_visitor.update_columns(created_at: 2.days.ago)
    @android_visitor.update_columns(created_at: 1.day.ago)

    params_p1 = @base_params.merge(per_page: 1, page: 1, sort_by: "created_at", ascendent: true)
    params_p2 = @base_params.merge(per_page: 1, page: 2, sort_by: "created_at", ascendent: true)
    result_p1 = query(params_p1).call
    result_p2 = query(params_p2).call

    assert_equal @ios_visitor.id, result_p1[:visitors].first["id"]
    assert_equal @android_visitor.id, result_p2[:visitors].first["id"]
  end

  # === All metric columns present ===

  test "call returns all metric columns as total_ prefixed" do
    result = query(@base_params).call
    row = result[:visitors].first

    VisitorDailyStatistic::METRIC_COLUMNS.each do |col|
      assert row.key?("total_#{col}"), "Expected total_#{col} in result, got keys: #{row.keys}"
    end
  end

  # === Legacy paginated_own_events (OLD API) ===

  test "paginated_own_events returns correct event counts for ios_visitor" do
    # ios_device has: view_event(engagement_time=5000), open_event(3000), install_event(0)
    result = VisitorStatisticsQuery.paginated_own_events(
      page: 1, event_type: "created_at", asc: false, project: @project,
      start_date: 1.year.ago, end_date: Date.tomorrow,
      visitor_id: @ios_visitor.id
    )

    # Use .to_a.first to avoid Rails adding ORDER BY "visitors"."id" on the
    # wrapped subquery (whose alias is visitors_with_counts, not visitors).
    row = result[:metrics].to_a.first
    assert_not_nil row
    assert_equal 1, row["view_count"].to_i
    assert_equal 1, row["open_count"].to_i
    assert_equal 1, row["install_count"].to_i
    assert_equal 0, row["reinstall_count"].to_i, "ios_device has no reinstall events"
    assert_equal 5000, row["view_engagement_time"].to_i
    assert_equal 3000, row["open_engagement_time"].to_i
    assert_equal 0, row["install_engagement_time"].to_i
  end

  test "paginated_own_events returns correct event counts for android_visitor" do
    # android_device has: android_view_event(engagement_time=2000), reinstall_event(0)
    result = VisitorStatisticsQuery.paginated_own_events(
      page: 1, event_type: "created_at", asc: false, project: @project,
      start_date: 1.year.ago, end_date: Date.tomorrow,
      visitor_id: @android_visitor.id
    )

    row = result[:metrics].to_a.first
    assert_not_nil row
    assert_equal 1, row["view_count"].to_i
    assert_equal 1, row["reinstall_count"].to_i
    assert_equal 0, row["open_count"].to_i, "android_device has no open events"
    assert_equal 0, row["install_count"].to_i, "android_device has no install events"
    assert_equal 2000, row["view_engagement_time"].to_i
  end

  test "paginated_own_events excludes events from other projects" do
    other_project = projects(:two)
    # Create an event on another project for the same device
    Event.create!(
      project: other_project, device: devices(:ios_device),
      event: "view", engagement_time: 9999, platform: "ios"
    )

    result = VisitorStatisticsQuery.paginated_own_events(
      page: 1, event_type: "created_at", asc: false, project: @project,
      start_date: 1.year.ago, end_date: Date.tomorrow,
      visitor_id: @ios_visitor.id
    )

    row = result[:metrics].to_a.first
    # Should still be 1, not 2 — the other-project event must be excluded
    assert_equal 1, row["view_count"].to_i
    # Engagement time should NOT include the 9999 from the other project
    assert_equal 5000, row["view_engagement_time"].to_i
  end

  test "paginated_own_events sorts by created_at ascending and descending" do
    @ios_visitor.update_columns(created_at: 2.days.ago, updated_at: Time.current)
    @android_visitor.update_columns(created_at: 1.day.ago, updated_at: Time.current)

    asc_result = VisitorStatisticsQuery.paginated_own_events(
      page: 1, event_type: "created_at", asc: true, project: @project,
      start_date: 1.year.ago, end_date: Date.tomorrow
    )
    desc_result = VisitorStatisticsQuery.paginated_own_events(
      page: 1, event_type: "created_at", asc: false, project: @project,
      start_date: 1.year.ago, end_date: Date.tomorrow
    )

    asc_ids = asc_result[:metrics].to_a.map { |r| r["id"] }
    desc_ids = desc_result[:metrics].to_a.map { |r| r["id"] }

    assert_equal asc_ids.reverse, desc_ids, "ASC and DESC should produce opposite ordering"
    assert_equal @ios_visitor.id, asc_ids.first, "Older visitor should be first in ASC"
    assert_equal @android_visitor.id, desc_ids.first, "Newer visitor should be first in DESC"
  end

  test "paginated_own_events filters by updated_at date range" do
    # Set ios_visitor inside the range, android_visitor outside
    @ios_visitor.update_columns(updated_at: Date.parse("2026-03-01").noon)
    @android_visitor.update_columns(updated_at: Date.parse("2026-06-01").noon)

    result = VisitorStatisticsQuery.paginated_own_events(
      page: 1, event_type: "created_at", asc: false, project: @project,
      start_date: Date.parse("2026-03-01"), end_date: Date.parse("2026-03-02")
    )

    ids = result[:metrics].to_a.map { |r| r["id"] }
    assert_includes ids, @ios_visitor.id, "Visitor within date range should be included"
    assert_not_includes ids, @android_visitor.id, "Visitor outside date range should be excluded"
  end

  test "paginated_own_events filters by search term" do
    @ios_visitor.update_columns(sdk_identifier: "legacy-search-unique-xyz")

    result = VisitorStatisticsQuery.paginated_own_events(
      page: 1, event_type: "created_at", asc: false, project: @project,
      start_date: 1.year.ago, end_date: Date.tomorrow,
      term: "legacy-search-unique"
    )

    assert_equal 1, result[:total_entries]
  end

  test "paginated_own_events paginates correctly" do
    result = VisitorStatisticsQuery.paginated_own_events(
      page: 1, event_type: "created_at", asc: false, project: @project,
      start_date: 1.year.ago, end_date: Date.tomorrow,
      per_page: 1
    )

    assert_equal 1, result[:metrics].to_a.size
    assert_equal 2, result[:total_pages], "2 visitors / per_page=1 = 2 pages"
  end

  test "paginated_own_events returns zero counts for visitor with no events" do
    new_device = Device.create!(user_agent: "NoEvents/1.0", ip: "1.1.1.1", remote_ip: "2.2.2.2", platform: "ios")
    new_visitor = Visitor.create!(project: @project, device: new_device)

    result = VisitorStatisticsQuery.paginated_own_events(
      page: 1, event_type: "created_at", asc: false, project: @project,
      start_date: 1.year.ago, end_date: Date.tomorrow,
      visitor_id: new_visitor.id
    )

    row = result[:metrics].to_a.first
    assert_not_nil row
    Grovs::Events::ALL.each do |et|
      assert_equal 0, row["#{et}_count"].to_i, "Expected #{et}_count to be 0"
      assert_equal 0, row["#{et}_engagement_time"].to_i, "Expected #{et}_engagement_time to be 0"
    end
  end

  private

  def query(params, project: @project)
    VisitorStatisticsQuery.new(params: params, project: project)
  end
end
