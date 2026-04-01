require "test_helper"

class CampaignQueryServiceTest < ActiveSupport::TestCase
  fixtures :projects, :instances, :campaigns

  setup do
    @project = projects(:one)
    @service = CampaignQueryService.new(project: @project)

    # Create campaigns with distinct names and controlled timestamps for deterministic tests.
    @alpha = Campaign.create!(
      name: "Alpha Campaign", project: @project,
      created_at: 3.days.ago, updated_at: 1.day.ago
    )
    @beta = Campaign.create!(
      name: "Beta Campaign", project: @project,
      created_at: 1.day.ago, updated_at: 3.days.ago
    )
    @archived_camp = Campaign.create!(
      name: "Archived Campaign", project: @project,
      archived: true, created_at: 2.days.ago, updated_at: 2.days.ago
    )
  end

  # --- search: archived filtering ---

  test "search returns only non-archived campaigns when archived is false" do
    result = @service.search(archived: false)
    # campaigns(:one) fixture + @alpha + @beta from setup = 3 non-archived
    assert_equal 3, result.size
    result.each { |c| assert_not c.archived }
  end

  test "search returns only archived campaigns when archived is true" do
    result = @service.search(archived: true)
    result.each { |c| assert c.archived }
    assert result.any? { |c| c.name == "Archived Campaign" }
  end

  # --- search: project scoping ---

  test "search scopes to the given project" do
    result = @service.search(archived: false)
    result.each { |c| assert_equal @project.id, c.project_id }
  end

  test "search returns empty for project with no matching campaigns" do
    other_service = CampaignQueryService.new(project: projects(:two))
    # projects(:two) may have fixture campaign "two" but we test archived: true
    result = other_service.search(archived: true)
    assert_empty result
  end

  # --- search: term filtering ---

  test "search filters by term and returns matching campaign" do
    result = @service.search(archived: false, term: "Alpha")
    names = result.map(&:name)
    assert_includes names, "Alpha Campaign"
    assert_not_includes names, "Beta Campaign"
  end

  test "search term is case insensitive" do
    result = @service.search(archived: false, term: "alpha")
    assert result.any? { |c| c.name == "Alpha Campaign" }
  end

  test "search term with no matches returns empty" do
    result = @service.search(archived: false, term: "zzz_nonexistent_xyz")
    assert_empty result
  end

  # --- search: sorting ---

  test "search sorts by name ascending" do
    result = @service.search(archived: false, sort_by: "name", asc: true)
    names = result.map(&:name)
    assert_equal names.sort, names
  end

  test "search sorts by name descending" do
    result = @service.search(archived: false, sort_by: "name", asc: false)
    names = result.map(&:name)
    assert_equal names.sort.reverse, names
  end

  test "search sorts by created_at ascending" do
    result = @service.search(archived: false, sort_by: "created_at", asc: true)
    created_ats = result.map(&:created_at)
    created_ats.each_cons(2) do |a, b|
      assert a <= b, "Expected created_at asc order, got #{a} before #{b}"
    end
  end

  test "search defaults to updated_at desc for invalid sort column" do
    result = @service.search(archived: false, sort_by: "invalid_column")
    updated_ats = result.map(&:updated_at)
    updated_ats.each_cons(2) do |a, b|
      assert a >= b, "Expected updated_at desc order, got #{a} before #{b}"
    end
  end

  # --- search: pagination ---

  test "search paginates to requested per_page" do
    result = @service.search(archived: false, page: 1, per_page: 1)
    assert_equal 1, result.size
  end

  test "search page 2 returns different results than page 1" do
    # 3 non-archived campaigns, so page 2 with per_page: 1 will have data
    page1 = @service.search(archived: false, page: 1, per_page: 1)
    page2 = @service.search(archived: false, page: 2, per_page: 1)
    assert page2.any?, "Expected page 2 to have results (3 campaigns with per_page: 1)"
    assert_not_equal page1.map(&:id), page2.map(&:id)
  end

  # --- search: date range ---

  test "search filters by date range returns empty for old dates" do
    result = @service.search(archived: false, start_date: "2020-01-01", end_date: "2020-01-02")
    assert_empty result
  end

  test "search filters by date range includes campaigns within range" do
    result = @service.search(archived: false,
                             start_date: 5.days.ago.to_date.to_s,
                             end_date: Date.today.to_s)
    names = result.map(&:name)
    assert_includes names, "Alpha Campaign"
    assert_includes names, "Beta Campaign"
  end

  # --- search: combined filters ---

  test "search combines archived and term filters" do
    result = @service.search(archived: true, term: "Archived")
    # Only @archived_camp matches archived=true and term "Archived"
    assert_equal 1, result.size
    result.each do |c|
      assert c.archived
      assert_match(/archived/i, c.name)
    end
  end

  test "search with archived true and non-matching term returns empty" do
    result = @service.search(archived: true, term: "Alpha")
    assert_empty result, "Alpha is not archived, so no match expected"
  end

  # --- filter method ---

  test "filter returns matching campaigns without pagination" do
    result = @service.filter(archived: false)
    assert_not result.respond_to?(:total_pages)
    assert result.any? { |c| c.name == "Alpha Campaign" }
  end

  test "filter applies term and returns only matching campaigns" do
    result = @service.filter(archived: false, term: "Beta")
    names = result.map(&:name)
    assert_includes names, "Beta Campaign"
    assert_not_includes names, "Alpha Campaign"
  end

  test "filter scopes to project" do
    result = @service.filter(archived: false)
    result.each { |c| assert_equal @project.id, c.project_id }
  end

  # --- filter method with date params ---

  test "filter with start_date and end_date excludes campaigns outside range" do
    old_campaign = Campaign.create!(
      name: "Old Campaign", project: @project,
      created_at: 60.days.ago
    )

    result = @service.filter(
      archived: false,
      start_date: 5.days.ago.to_date.to_s,
      end_date: Date.today.to_s
    )

    names = result.map(&:name)
    assert_not_includes names, "Old Campaign", "Campaign created 60 days ago should be excluded by date range"
    assert_includes names, "Alpha Campaign", "Campaign within date range should be included"
  end
end
