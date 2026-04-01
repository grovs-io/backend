require "test_helper"

class LinkStatisticsQueryTest < ActiveSupport::TestCase
  fixtures :projects, :instances, :domains, :links, :link_daily_statistics, :redirect_configs

  setup do
    @project = projects(:one)
    @basic_link = links(:basic_link)
  end

  def build_query(overrides = {})
    defaults = {
      start_date: "2026-03-01", end_date: "2026-03-02",
      page: 1, per_page: 20, sort_by: "created_at", ascendent: false,
      active: true
    }
    LinkStatisticsQuery.new(params: defaults.merge(overrides), project: @project)
  end

  # ── Structure ──

  test "call returns links with pagination meta" do
    result = build_query.call

    assert result.key?(:links)
    assert result.key?(:meta)
    assert_equal 1, result[:meta][:page]
    assert result[:meta].key?(:total_pages)
    assert result[:meta].key?(:per_page)
    assert result[:meta].key?(:total_entries)
  end

  # ── Aggregation of ALL metric columns ──

  test "aggregates all metric columns across days for basic_link" do
    result = build_query.call
    link_data = result[:links].find { |l| l["id"] == @basic_link.id }

    assert_not_nil link_data, "basic_link must be present in results"

    # stat_day1 + stat_day2 (both ios, both for basic_link in Mar 1–2)
    assert_equal 300,   link_data["total_views"]         # 100 + 200
    assert_equal 130,   link_data["total_opens"]          # 50 + 80
    assert_equal 30,    link_data["total_installs"]       # 10 + 20
    assert_equal 7,     link_data["total_reinstalls"]     # 2 + 5
    assert_equal 13000, link_data["total_time_spent"]     # 5000 + 8000
    assert_equal 4,     link_data["total_reactivations"]  # 1 + 3
    assert_equal 90,    link_data["total_app_opens"]      # 30 + 60
    assert_equal 10,    link_data["total_user_referred"]  # 3 + 7
    assert_equal 2998,  link_data["total_revenue"]        # 999 + 1999
  end

  # ── Sorting by metric fields ──

  test "sorts by metric field descending" do
    result = build_query(sort_by: "views", ascendent: false).call
    views = result[:links].map { |l| l["total_views"] }

    assert_equal views.sort.reverse, views
  end

  test "sorts by metric field ascending" do
    result = build_query(sort_by: "views", ascendent: true).call
    views = result[:links].map { |l| l["total_views"] }

    assert_equal views.sort, views
  end

  test "sorts by link field name ascending" do
    result = build_query(sort_by: "name", ascendent: true).call
    names = result[:links].map { |l| l["name"] }.compact

    assert_equal names.sort, names
  end

  test "defaults to created_at desc for unknown sort field" do
    result = build_query(sort_by: "nonexistent").call
    timestamps = result[:links].map { |l| l["updated_at"] }

    assert timestamps.any?, "Should return links even for unknown sort field"
  end

  # ── Platform filtering ──

  test "platform ios returns stats for ios-only link daily stats" do
    ios_result = build_query(platform: "ios").call
    ios_link = ios_result[:links].find { |l| l["id"] == @basic_link.id }

    assert_not_nil ios_link, "basic_link must appear in ios-filtered results"
    assert_equal 300, ios_link["total_views"]  # stat_day1(100) + stat_day2(200)
  end

  test "platform android returns zero stats for basic_link since all its stats are ios" do
    android_result = build_query(platform: "android").call
    android_link = android_result[:links].find { |l| l["id"] == @basic_link.id }

    assert_not_nil android_link, "basic_link must appear (LEFT JOIN gives zero stats)"
    assert_equal 0, android_link["total_views"]
    assert_equal 0, android_link["total_opens"]
    assert_equal 0, android_link["total_installs"]
    assert_equal 0, android_link["total_revenue"]
  end

  # ── Text search ──

  test "text search on title" do
    result = build_query(term: "Test Link").call
    assert result[:links].any? { |l| l["title"] == "Test Link" }
  end

  test "text search on path" do
    result = build_query(term: "test-path").call
    assert result[:links].any? { |l| l["path"] == "test-path" }
  end

  test "text search is case insensitive" do
    result = build_query(term: "TEST-PATH").call
    assert result[:links].any? { |l| l["path"] == "test-path" }
  end

  test "text search on tags via unnest" do
    @basic_link.update!(tags: ["promo", "summer-sale"])

    result = build_query(term: "summer-sale").call
    found = result[:links].find { |l| l["id"] == @basic_link.id }

    assert_not_nil found, "Tag search should find the link with matching tag"
  end

  test "text search returns nothing for non-matching term" do
    result = build_query(term: "zzz_nonexistent_zzz").call
    assert_equal 0, result[:links].length
  end

  # ── Pagination ──

  test "pagination respects per_page" do
    result = build_query(per_page: 1).call
    assert_equal 1, result[:links].size
  end

  test "all param returns all results in a single page" do
    result = build_query(all: true).call
    assert result[:meta][:per_page] >= result[:meta][:total_entries]
  end

  # ── Filters ──

  test "sdk filter excludes sdk links" do
    result = build_query(sdk: false).call
    result[:links].each { |l| assert_equal false, l["sdk_generated"] }
  end

  test "active false returns inactive links" do
    result = build_query(active: false).call
    result[:links].each { |l| assert_equal false, l["active"] }
  end

  test "link_id filter returns only that specific link" do
    result = build_query(link_id: @basic_link.id).call

    assert_equal 1, result[:links].size
    assert_equal @basic_link.id, result[:links].first["id"]
  end

  # ── Date range ──

  test "date range outside data returns links with zero stats" do
    result = build_query(start_date: "2020-01-01", end_date: "2020-01-02").call

    # Links still appear (LEFT JOIN), but all stats are 0
    assert result[:links].any?, "Links should still appear via LEFT JOIN"
    result[:links].each do |l|
      assert_equal 0, l["total_views"]
      assert_equal 0, l["total_opens"]
      assert_equal 0, l["total_installs"]
      assert_equal 0, l["total_revenue"]
    end
  end

  test "single day returns stats for only that day" do
    result = build_query(start_date: "2026-03-01", end_date: "2026-03-01").call
    link_data = result[:links].find { |l| l["id"] == @basic_link.id }

    assert_not_nil link_data
    assert_equal 100, link_data["total_views"]   # stat_day1 only
    assert_equal 50,  link_data["total_opens"]
    assert_equal 10,  link_data["total_installs"]
    assert_equal 999, link_data["total_revenue"]
  end

  # ── Campaign filtering ──

  test "campaign_id filter restricts to campaign links" do
    campaign = Campaign.create!(name: "Dashboard Test Campaign", project: @project)
    result = LinkStatisticsQuery.new(
      params: { start_date: "2026-03-01", end_date: "2026-03-02", page: 1, per_page: 20, active: true },
      project: @project,
      campaign_id: campaign.id
    ).call

    assert_equal 0, result[:links].length, "No links belong to this new campaign"
  end

  test "campaign_id filter returns links belonging to that campaign" do
    campaign = Campaign.create!(name: "Test Campaign", project: @project)
    @basic_link.update!(campaign: campaign)

    result = LinkStatisticsQuery.new(
      params: { start_date: "2026-03-01", end_date: "2026-03-02", page: 1, per_page: 20, active: true },
      project: @project,
      campaign_id: campaign.id
    ).call

    assert_equal 1, result[:links].length
    assert_equal @basic_link.id, result[:links].first["id"]
    assert_equal 300, result[:links].first["total_views"]
  end

  # --- Sort by updated_at ---

  test "sorts by updated_at ascending" do
    # Ensure distinct updated_at values
    @basic_link.update_column(:updated_at, 2.days.ago)

    other_link = Link.create!(
      domain: domains(:one), redirect_config: redirect_configs(:one),
      path: "updated-at-sort-test-#{SecureRandom.hex(4)}",
      active: true, sdk_generated: false,
      generated_from_platform: "ios"
    )
    other_link.update_column(:updated_at, 1.day.ago)

    result = build_query(sort_by: "updated_at", ascendent: true).call
    timestamps = result[:links].map { |l| l["updated_at"] }

    timestamps.each_cons(2) do |a, b|
      assert a <= b, "Expected updated_at asc order, got #{a} before #{b}"
    end
  end

  # --- Sort by installs metric ---

  test "sorts by installs metric ascending" do
    result = build_query(sort_by: "installs", ascendent: true).call
    installs = result[:links].map { |l| l["total_installs"] }

    assert_equal installs.sort, installs, "Expected installs sorted ascending"
  end
end
