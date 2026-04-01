require "test_helper"

class CampaignStatisticsQueryTest < ActiveSupport::TestCase
  fixtures :projects, :instances, :domains, :links, :campaigns, :redirect_configs

  setup do
    @project = projects(:one)
    @campaign = Campaign.create!(name: "Stats Campaign", project: @project)
    @link = Link.create!(
      domain: domains(:one), redirect_config: redirect_configs(:one),
      path: "campaign-stats-#{SecureRandom.hex(4)}", campaign: @campaign,
      active: true, sdk_generated: false, data: "[]",
      generated_from_platform: "ios"
    )

    # Create link daily stats for this campaign link
    LinkDailyStatistic.insert_all([
      {
        link_id: @link.id, project_id: @project.id,
        event_date: Date.new(2026, 3, 1), platform: "ios",
        views: 100, opens: 50, installs: 10, reinstalls: 2,
        time_spent: 5000, reactivations: 1, app_opens: 30,
        user_referred: 3, revenue: 999,
        created_at: Time.current, updated_at: Time.current
      },
      {
        link_id: @link.id, project_id: @project.id,
        event_date: Date.new(2026, 3, 2), platform: "ios",
        views: 200, opens: 80, installs: 20, reinstalls: 5,
        time_spent: 8000, reactivations: 3, app_opens: 60,
        user_referred: 7, revenue: 1999,
        created_at: Time.current, updated_at: Time.current
      }
    ])
  end

  def build_query(overrides = {})
    defaults = {
      start_date: "2026-03-01", end_date: "2026-03-02",
      page: 1, per_page: 20
    }
    CampaignStatisticsQuery.new(project: @project, params: defaults.merge(overrides))
  end

  # --- Aggregation ---

  test "returns campaigns with all nine aggregated metric columns" do
    result = build_query.call
    entry = result.find { |c| c.id == @campaign.id }

    assert_not_nil entry
    assert_equal 300,   entry.total_views.to_i          # 100 + 200
    assert_equal 130,   entry.total_opens.to_i          # 50 + 80
    assert_equal 30,    entry.total_installs.to_i       # 10 + 20
    assert_equal 7,     entry.total_reinstalls.to_i     # 2 + 5
    assert_equal 13000, entry.total_time_spent.to_i     # 5000 + 8000
    assert_equal 4,     entry.total_reactivations.to_i  # 1 + 3
    assert_equal 90,    entry.total_app_opens.to_i      # 30 + 60
    assert_equal 10,    entry.total_user_referred.to_i  # 3 + 7
    assert_equal 2998,  entry.total_revenue.to_i        # 999 + 1999
  end

  test "aggregates stats across multiple links in the same campaign" do
    second_link = Link.create!(
      domain: domains(:one), redirect_config: redirect_configs(:one),
      path: "campaign-stats-multi-#{SecureRandom.hex(4)}", campaign: @campaign,
      active: true, sdk_generated: false, data: "[]",
      generated_from_platform: "ios"
    )

    LinkDailyStatistic.insert_all([
      {
        link_id: second_link.id, project_id: @project.id,
        event_date: Date.new(2026, 3, 1), platform: "ios",
        views: 50, opens: 25, installs: 5, reinstalls: 1,
        time_spent: 2000, reactivations: 0, app_opens: 15,
        user_referred: 2, revenue: 500,
        created_at: Time.current, updated_at: Time.current
      }
    ])

    result = build_query.call
    entry = result.find { |c| c.id == @campaign.id }

    assert_not_nil entry
    # Original 2 rows: views 100+200=300, plus second_link: 50 => 350
    assert_equal 350,  entry.total_views.to_i
    assert_equal 155,  entry.total_opens.to_i          # 50 + 80 + 25
    assert_equal 35,   entry.total_installs.to_i       # 10 + 20 + 5
    assert_equal 8,    entry.total_reinstalls.to_i     # 2 + 5 + 1
    assert_equal 15000, entry.total_time_spent.to_i    # 5000 + 8000 + 2000
    assert_equal 4,    entry.total_reactivations.to_i  # 1 + 3 + 0
    assert_equal 105,  entry.total_app_opens.to_i      # 30 + 60 + 15
    assert_equal 12,   entry.total_user_referred.to_i  # 3 + 7 + 2
    assert_equal 3498, entry.total_revenue.to_i        # 999 + 1999 + 500
  end

  test "returns zero stats for campaigns without links" do
    empty_campaign = Campaign.create!(name: "Empty Campaign", project: @project)
    result = build_query.call
    entry = result.find { |c| c.id == empty_campaign.id }

    assert_not_nil entry
    assert_equal 0, entry.total_views.to_i
    assert_equal 0, entry.total_installs.to_i
    assert_equal 0, entry.total_revenue.to_i
  end

  # --- Filtering ---

  test "filters by campaign name" do
    Campaign.create!(name: "Other Campaign", project: @project)
    result = build_query(term: "Stats").call

    assert result.any? { |c| c.name == "Stats Campaign" }
    assert result.none? { |c| c.name == "Other Campaign" }
  end

  test "filters by archived status" do
    Campaign.create!(name: "Archived", project: @project, archived: true)

    active = build_query(archived: false).call
    archived = build_query(archived: true).call

    active.each { |c| assert_not c.archived }
    archived.each { |c| assert c.archived }
  end

  # --- Sorting ---

  test "sorts by campaign field ascending" do
    Campaign.create!(name: "AAA First", project: @project)
    result = build_query(sort_by: "name", ascendent: true).call
    names = result.map(&:name)

    assert_equal names, names.sort
  end

  test "sorts by metric field descending" do
    result = build_query(sort_by: "views", ascendent: false).call
    views = result.map { |c| c.total_views.to_i }

    assert_equal views, views.sort.reverse
  end

  test "defaults to created_at desc for unknown sort field" do
    older_campaign = Campaign.create!(name: "Older", project: @project)
    older_campaign.update_column(:created_at, 2.days.ago)

    newer_campaign = Campaign.create!(name: "Newer", project: @project)
    newer_campaign.update_column(:created_at, 1.hour.ago)

    result = build_query(sort_by: "invalid_field").call
    campaign_ids = result.map(&:id)

    older_index = campaign_ids.index(older_campaign.id)
    newer_index = campaign_ids.index(newer_campaign.id)

    assert_not_nil older_index, "Older campaign should appear in results"
    assert_not_nil newer_index, "Newer campaign should appear in results"
    assert newer_index < older_index, "Newer campaign should come before older (DESC order)"
  end

  # --- Platform filter ---

  test "platform filter restricts stats aggregation" do
    result = build_query(platform: "android").call
    entry = result.find { |c| c.id == @campaign.id }

    # All stats are ios, android filter should yield 0
    assert_equal 0, entry.total_views.to_i
  end

  # --- Pagination ---

  test "paginates results" do
    result = build_query(per_page: 1).call
    assert_equal 1, result.to_a.length
  end

  # --- Scoping ---

  test "scopes to project" do
    result = build_query.call
    result.each { |c| assert_equal @project.id, c.project_id }
  end

  # --- Date range ---

  test "date range outside data returns zero stats" do
    result = CampaignStatisticsQuery.new(
      project: @project,
      params: { start_date: "2020-01-01", end_date: "2020-01-02", page: 1 }
    ).call

    result.each { |c| assert_equal 0, c.total_views.to_i }
  end

  # --- Sort by created_at ascending (SORTABLE_CAMPAIGN_FIELD) ---

  test "sorts by created_at ascending" do
    older = Campaign.create!(name: "Older Campaign", project: @project)
    older.update_column(:created_at, 5.days.ago)

    newer = Campaign.create!(name: "Newer Campaign", project: @project)
    newer.update_column(:created_at, 1.hour.ago)

    result = build_query(sort_by: "created_at", ascendent: true).call
    created_ats = result.map(&:created_at)

    created_ats.each_cons(2) do |a, b|
      assert a <= b, "Expected created_at asc order, got #{a} before #{b}"
    end
  end

  # --- Metric sort ascending (installs) ---

  test "sorts by installs metric ascending" do
    # Create a second campaign with more installs to verify ascending sort
    high_installs_campaign = Campaign.create!(name: "High Installs", project: @project)
    high_link = Link.create!(
      domain: domains(:one), redirect_config: redirect_configs(:one),
      path: "high-installs-#{SecureRandom.hex(4)}", campaign: high_installs_campaign,
      active: true, sdk_generated: false, data: "[]",
      generated_from_platform: "ios"
    )

    LinkDailyStatistic.insert_all([
      {
        link_id: high_link.id, project_id: @project.id,
        event_date: Date.new(2026, 3, 1), platform: "ios",
        views: 10, opens: 5, installs: 500, reinstalls: 0,
        time_spent: 100, reactivations: 0, app_opens: 5,
        user_referred: 0, revenue: 0,
        created_at: Time.current, updated_at: Time.current
      }
    ])

    result = build_query(sort_by: "installs", ascendent: true).call
    installs = result.map { |c| c.total_installs.to_i }

    assert_equal installs.sort, installs, "Expected installs sorted ascending"
  end
end
