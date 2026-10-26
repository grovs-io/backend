require "test_helper"
require_relative "auth_test_helper"

class SmartBannerHiddenLinksApiTest < ActionDispatch::IntegrationTest
  include AuthTestHelper
  include SmartBannerTestHelper

  fixtures :instances, :users, :instance_roles, :projects, :domains, :redirect_configs, :links

  setup do
    @project = projects(:one)
    @headers = doorkeeper_headers_for(users(:admin_user))
    banner = create_test_banner(@project)
    @banner_link_ids = [banner.default_link_id, SmartBannerLinkService.fetch(banner, page_path: "/p", data: {}).id]
  end

  test "links/search_v2 never returns banner links" do
    [false, nil].each do |sdk|
      body = { active: true, sdk: sdk, ascending: false, page: 1, per_page: 100,
               start_date: "2026-01-01T00:00:00.000Z", sort_by: "updated_at" }.compact

      post "#{API_PREFIX}/projects/#{@project.id}/links/search_v2", params: body, headers: @headers, as: :json

      assert_response :ok
      json = JSON.parse(response.body)
      assert_empty json["links"].map { |l| l["id"] } & @banner_link_ids, "sdk=#{sdk.inspect}"
      assert_includes json["links"].map { |l| l["id"] }, links(:basic_link).id
      assert_equal json["links"].size, json["meta"]["total_entries"]
    end
  end

  test "links/lookup never returns banner links" do
    get "#{API_PREFIX}/projects/#{@project.id}/links/lookup", params: { limit: 50 }, headers: @headers

    assert_response :ok
    ids = JSON.parse(response.body)["links"].map { |l| l["id"] }
    assert_empty ids & @banner_link_ids
    assert_includes ids, links(:basic_link).id
  end
end
