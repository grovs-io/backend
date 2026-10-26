require "test_helper"

class LinkQueryServiceTest < ActiveSupport::TestCase
  fixtures :projects, :instances, :domains, :links, :redirect_configs, :campaigns

  setup do
    @domain = domains(:one)
    @redirect_config = redirect_configs(:one)
    @service = LinkQueryService.new(domain: @domain)

    # Create links with distinct, predictable values for sorting and filtering tests.
    # All use unique paths so the path_must_be_unique validation passes.
    @link_apple = Link.create!(
      domain: @domain, redirect_config: @redirect_config,
      path: "zzz-apple-path", name: "Apple Link", title: "Apple Title",
      subtitle: "Fruit subtitle", generated_from_platform: "ios",
      active: true, sdk_generated: false, created_at: 3.days.ago
    )
    @link_banana = Link.create!(
      domain: @domain, redirect_config: @redirect_config,
      path: "aaa-banana-path", name: "Banana Link", title: "Banana Title",
      subtitle: "Fruit subtitle", generated_from_platform: "ios",
      active: true, sdk_generated: false, created_at: 1.day.ago
    )
    @link_sdk = Link.create!(
      domain: @domain, redirect_config: @redirect_config,
      path: "sdk-generated-path", name: "SDK Link", title: "SDK Title",
      subtitle: "Auto-generated", generated_from_platform: "ios",
      active: true, sdk_generated: true, created_at: 2.days.ago
    )
  end

  # --- search: active/sdk filtering ---

  test "search returns only active non-sdk links and excludes inactive and sdk links" do
    result = @service.search(active: true, sdk: false)
    result_paths = result.map(&:path)

    # Verify setup links are included
    assert_includes result_paths, "zzz-apple-path"
    assert_includes result_paths, "aaa-banana-path"

    # Verify sdk and inactive links are excluded
    assert_not_includes result_paths, "sdk-generated-path"
    assert_not_includes result_paths, "inactive-path"

    # Verify all returned links match the filter criteria
    result.each do |link|
      assert link.active, "Expected only active links, got inactive: #{link.path}"
      assert_not link.sdk_generated, "Expected only non-sdk links, got sdk: #{link.path}"
    end
  end

  test "search returns only inactive links when active is false" do
    result = @service.search(active: false, sdk: false)
    result.each { |l| assert_not l.active }
    assert result.any? { |l| l.path == "inactive-path" }, "Expected inactive fixture link"
  end

  test "search filters by sdk_generated true" do
    result = @service.search(active: true, sdk: true)
    result.each { |l| assert l.sdk_generated }
    assert result.any? { |l| l.path == "sdk-generated-path" }
  end

  test "search filters by sdk_generated false excludes sdk links" do
    result = @service.search(active: true, sdk: false)
    result.each { |l| assert_not l.sdk_generated }
    assert_not result.any? { |l| l.path == "sdk-generated-path" }
  end

  # --- search: term filtering ---

  test "search filters by term matching path" do
    result = @service.search(active: true, sdk: false, term: "apple-path")
    paths = result.map(&:path)
    assert_includes paths, "zzz-apple-path"
    assert_not_includes paths, "aaa-banana-path"
  end

  test "search filters by term matching name" do
    result = @service.search(active: true, sdk: false, term: "Banana Link")
    names = result.map(&:name)
    assert_includes names, "Banana Link"
    assert_not_includes names, "Apple Link"
  end

  test "search term is case insensitive" do
    result = @service.search(active: true, sdk: false, term: "APPLE TITLE")
    assert result.any? { |l| l.title == "Apple Title" }
  end

  test "search term matching subtitle" do
    result = @service.search(active: true, sdk: false, term: "Fruit subtitle")
    paths = result.map(&:path)
    assert_includes paths, "zzz-apple-path"
    assert_includes paths, "aaa-banana-path"
  end

  test "search treats % and _ in term as literal characters" do
    literal = Link.create!(domain: @domain, redirect_config: @redirect_config,
                            path: "search-lit_eral-path", name: "50% deal", generated_from_platform: "ios",
                            active: true, sdk_generated: false)
    lookalike = Link.create!(domain: @domain, redirect_config: @redirect_config,
                              path: "search-litXeral-path", name: "50xdeal", generated_from_platform: "ios",
                              active: true, sdk_generated: false)

    percent_ids = @service.search(active: true, sdk: false, term: "50%").map(&:id)
    assert_includes percent_ids, literal.id
    assert_not_includes percent_ids, lookalike.id

    underscore_ids = @service.search(active: true, sdk: false, term: "lit_eral").map(&:id)
    assert_includes underscore_ids, literal.id
    assert_not_includes underscore_ids, lookalike.id
  end

  # --- search: sorting ---

  test "search sorts by path ascending" do
    result = @service.search(active: true, sdk: false, sort_by: "path", asc: true)
    paths = result.map(&:path)
    assert_equal paths.sort, paths, "Expected paths sorted ascending"
  end

  test "search sorts by path descending" do
    result = @service.search(active: true, sdk: false, sort_by: "path", asc: false)
    paths = result.map(&:path)
    assert_equal paths.sort.reverse, paths, "Expected paths sorted descending"
  end

  test "search defaults to created_at desc for invalid sort column" do
    result = @service.search(active: true, sdk: false, sort_by: "DROP TABLE links")
    created_ats = result.map(&:created_at)
    # Verify descending order: each element >= the next
    created_ats.each_cons(2) do |a, b|
      assert a >= b, "Expected created_at desc order, got #{a} before #{b}"
    end
  end

  test "search sorts by name ascending" do
    result = @service.search(active: true, sdk: false, sort_by: "name", asc: true)
    names = result.map(&:name).compact
    assert_equal names.sort, names
  end

  # --- search: pagination ---

  test "search paginates to requested per_page" do
    result = @service.search(active: true, sdk: false, page: 1, per_page: 1)
    assert_equal 1, result.size
  end

  test "search per_page minimum is 1" do
    result = @service.search(active: true, sdk: false, per_page: 0)
    assert_equal 1, result.limit_value
  end

  test "search page 2 returns different results than page 1" do
    # 3 active non-sdk links on domain :one, so page 2 with per_page: 1 will have data
    page1 = @service.search(active: true, sdk: false, page: 1, per_page: 1)
    page2 = @service.search(active: true, sdk: false, page: 2, per_page: 1)
    assert page2.any?, "Expected page 2 to have results (3 links with per_page: 1)"
    assert_not_equal page1.map(&:id), page2.map(&:id), "Pages should contain different links"
  end

  # --- search: date range ---

  test "search filters by date range returns empty for old dates" do
    result = @service.search(active: true, sdk: false, start_date: "2020-01-01", end_date: "2020-01-02")
    assert_empty result
  end

  test "search filters by date range includes links within range" do
    result = @service.search(active: true, sdk: false,
                             start_date: 5.days.ago.to_date.to_s,
                             end_date: Date.today.to_s)
    paths = result.map(&:path)
    assert_includes paths, "zzz-apple-path"
    assert_includes paths, "aaa-banana-path"
  end

  # --- search: ads_platform ---

  test "search filters by ads_platform excludes non-matching" do
    result = @service.search(active: true, sdk: false, ads_platform: "nonexistent")
    assert_empty result
  end

  # --- search: campaign_id ---

  test "search filters by campaign_id" do
    campaign = campaigns(:one)
    @link_apple.update!(campaign: campaign)

    result = @service.search(active: true, sdk: false, campaign_id: campaign.id)
    assert_equal 1, result.size
    assert_equal @link_apple.id, result.first.id
  end

  # --- search: combined filters ---

  test "search combines active, term, and sdk filters" do
    result = @service.search(active: true, sdk: true, term: "SDK")
    assert result.all? { |l| l.active && l.sdk_generated }
    assert result.any? { |l| l.name == "SDK Link" }
  end

  # --- filter method ---

  test "filter returns matching links without pagination" do
    result = @service.filter(active: true, sdk: false, term: "apple")
    assert result.any? { |l| l.path == "zzz-apple-path" }
    assert_not result.respond_to?(:total_pages)
  end

  test "filter applies term and returns only matching links" do
    result = @service.filter(active: true, sdk: false, term: "banana")
    paths = result.map(&:path)
    assert_includes paths, "aaa-banana-path"
    assert_not_includes paths, "zzz-apple-path"
  end

  test "filter treats % and _ in term as literal characters" do
    literal = Link.create!(domain: @domain, redirect_config: @redirect_config,
                            path: "filter-lit_eral-path", name: "50% deal", generated_from_platform: "ios",
                            active: true, sdk_generated: false)
    lookalike = Link.create!(domain: @domain, redirect_config: @redirect_config,
                              path: "filter-litXeral-path", name: "50xdeal", generated_from_platform: "ios",
                              active: true, sdk_generated: false)

    percent_ids = @service.filter(active: true, sdk: false, term: "50%").map(&:id)
    assert_includes percent_ids, literal.id
    assert_not_includes percent_ids, lookalike.id

    underscore_ids = @service.filter(active: true, sdk: false, term: "lit_eral").map(&:id)
    assert_includes underscore_ids, literal.id
    assert_not_includes underscore_ids, lookalike.id
  end

  test "filter with campaign_id returns only links for that campaign" do
    campaign = campaigns(:one)
    @link_banana.update!(campaign: campaign)

    result = @service.filter(active: true, sdk: false, campaign_id: campaign.id)
    assert result.all? { |l| l.campaign_id == campaign.id }
    assert_equal 1, result.size
  end

  # --- domain scoping ---

  test "only returns links belonging to the given domain" do
    result = @service.search(active: true, sdk: false)
    result.each { |l| assert_equal @domain.id, l.domain_id }
  end

  test "does not return links from another domain" do
    other_domain = domains(:two)
    result = @service.search(active: true, sdk: false)
    assert_not result.any? { |l| l.domain_id == other_domain.id }
  end

  # --- filter method with date params ---

  test "filter with start_date and end_date excludes links outside range" do
    old_link = Link.create!(
      domain: @domain, redirect_config: @redirect_config,
      path: "old-link-#{SecureRandom.hex(4)}", name: "Old Link",
      generated_from_platform: "ios",
      active: true, sdk_generated: false,
      created_at: 60.days.ago
    )

    result = @service.filter(
      active: true, sdk: false,
      start_date: 5.days.ago.to_date.to_s,
      end_date: Date.today.to_s
    )

    paths = result.map(&:path)
    assert_not_includes paths, old_link.path, "Link created 60 days ago should be excluded by date range"
    assert_includes paths, @link_apple.path, "Link within date range should be included"
  end

  # --- per_page nil uses Kaminari default ---

  test "search without per_page param uses Kaminari default pagination" do
    result = @service.search(active: true, sdk: false, page: 1)
    # Should return results using Kaminari's default per_page (typically 25)
    assert result.any?, "Expected results with default pagination"
    assert result.respond_to?(:total_pages), "Expected a paginated result"
  end

  test "lookup ignores created_at, returning links regardless of age" do
    @link_apple.update!(created_at: 1.year.ago)
    result = @service.lookup
    assert_includes result.map(&:id), @link_apple.id
  end

  test "lookup excludes inactive and sdk_generated links" do
    result = @service.lookup
    ids = result.map(&:id)
    assert_not_includes ids, @link_sdk.id
    assert_not_includes ids, links(:inactive_link).id
  end

  test "lookup orders by created_at desc, not by updated_at" do
    # apple is older but freshly touched, so an updated_at ordering would wrongly sort it first.
    @link_apple.touch
    result = @service.lookup
    ids = result.map(&:id)
    assert_operator ids.index(@link_banana.id), :<, ids.index(@link_apple.id)
  end

  test "lookup term matches name/title/subtitle/path and is case insensitive" do
    result = @service.lookup(term: "BANANA")
    assert_equal [@link_banana.id], result.map(&:id)
  end

  test "lookup term treats % and _ literally" do
    literal = Link.create!(domain: @domain, redirect_config: @redirect_config,
                            path: "lit_eral-path", name: "50% deal", generated_from_platform: "ios",
                            active: true, sdk_generated: false)
    lookalike = Link.create!(domain: @domain, redirect_config: @redirect_config,
                              path: "litXeral-path", name: "50xdeal", generated_from_platform: "ios",
                              active: true, sdk_generated: false)

    result = @service.lookup(term: "lit_eral")
    ids = result.map(&:id)
    assert_includes ids, literal.id
    assert_not_includes ids, lookalike.id
  end

  test "lookup term accepts a non-string value without raising" do
    result = nil
    assert_nothing_raised { result = @service.lookup(term: 123) }
    assert_kind_of ActiveRecord::Relation, result
  end

  test "lookup limit defaults to 20" do
    assert_equal 20, @service.lookup.limit_value
  end

  test "lookup limit clamps above 50 down to 50" do
    assert_equal 50, @service.lookup(limit: 100).limit_value
  end

  test "lookup limit clamps below 1 up to 1" do
    assert_equal 1, @service.lookup(limit: 0).limit_value
  end
end
