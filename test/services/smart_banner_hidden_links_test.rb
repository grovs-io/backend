require "test_helper"

class SmartBannerHiddenLinksTest < ActiveSupport::TestCase
  include SmartBannerTestHelper
  include LinkMetricsHelper

  fixtures :instances, :users, :instance_roles, :projects, :domains, :redirect_configs, :links

  setup do
    @project = projects(:one)
    banner = create_test_banner(@project)
    @banner_link_ids = [banner.default_link_id, SmartBannerLinkService.fetch(banner, page_path: "/p", data: {}).id]
    @visible = Link.where(domain_id: @project.domain.id, active: true).where.not(id: @banner_link_ids)
  end

  test "search_v2 on the Postgres path leaves banner links out of rows and totals" do
    result = LinkStatisticsQuery.new(params: search_params, project: @project).call

    assert_empty result[:links].map { |l| l["id"] } & @banner_link_ids
    assert_equal @visible.count, result[:meta][:total_entries]
  end

  test "a direct link_id lookup still returns a banner link" do
    result = LinkStatisticsQuery.new(params: search_params.merge(link_id: @banner_link_ids.first), project: @project).call

    assert_equal [@banner_link_ids.first], result[:links].map { |l| l["id"] }
  end

  test "a link with NULL tags is still listed" do
    links(:basic_link).update_column(:tags, nil)

    ids = LinkStatisticsQuery.new(params: search_params, project: @project).call[:links].map { |l| l["id"] }

    assert_includes ids, links(:basic_link).id
  end

  test "a link whose tags array contains a NULL element is still listed" do
    links(:basic_link).class.connection.execute(
      "UPDATE links SET tags = ARRAY['promo', NULL]::text[] WHERE id = #{links(:basic_link).id}"
    )

    ids = LinkStatisticsQuery.new(params: search_params, project: @project).call[:links].map { |l| l["id"] }

    assert_includes ids, links(:basic_link).id
  end

  test "LinkQueryService search and filter leave banner links out" do
    service = LinkQueryService.new(domain: @project.domain)
    searched = service.search(active: true, sdk: false, start_date: 1.year.ago.to_date.to_s).map(&:id)
    filtered = service.filter(active: true, sdk: false, start_date: 1.year.ago.to_date.to_s).map(&:id)

    assert_empty searched & @banner_link_ids
    assert_empty filtered & @banner_link_ids
    assert_includes filtered, links(:basic_link).id
  end

  test "the export query leaves banner links out" do
    ids = fetch_links_for_search_params(@project.id, users(:admin_user).id, true, false, nil).map(&:id)

    assert_empty ids & @banner_link_ids
    assert_includes ids, links(:basic_link).id
  end

  private

  def search_params
    { start_date: "2026-03-01", end_date: "2026-03-02", page: 1, per_page: 100, sort_by: "created_at",
      ascendent: false, active: true }
  end
end
