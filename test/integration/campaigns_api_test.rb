require "test_helper"
require_relative "auth_test_helper"

class CampaignsApiTest < ActionDispatch::IntegrationTest
  include AuthTestHelper

  fixtures :instances, :users, :instance_roles, :projects, :domains,
           :redirect_configs, :campaigns

  setup do
    @admin_user = users(:admin_user)
    @project = projects(:one)
    @project_two = projects(:two)
    @campaign = campaigns(:one)
    @headers = doorkeeper_headers_for(@admin_user)
  end

  # --- Unauthenticated ---

  test "create campaign without auth returns 401 with no data" do
    post "#{API_PREFIX}/projects/#{@project.id}/campaigns",
      params: { name: "Test Campaign" },
      headers: api_headers
    assert_response :unauthorized
    assert_no_match(/"campaign"/, response.body, "401 must not contain campaign data")
  end

  # --- Create Campaign ---

  test "create campaign persists and returns correct data" do
    assert_difference "Campaign.count", 1 do
      post "#{API_PREFIX}/projects/#{@project.id}/campaigns",
        params: { name: "New Campaign" },
        headers: @headers
    end
    assert_response :ok
    json = JSON.parse(response.body)
    assert_equal "New Campaign", json["campaign"]["name"]
    assert_not json["campaign"]["archived"], "new campaign must not be archived"

    created = Campaign.find_by(name: "New Campaign")
    assert_not_nil created
    assert_equal @project.id, created.project_id
  end

  # --- Search Campaigns ---

  test "search campaigns returns paginated results with fixture campaign" do
    post "#{API_PREFIX}/projects/#{@project.id}/campaigns/search",
      params: { archived: "false", page: 1, sort_by: "view", ascendent: "false" },
      headers: @headers
    assert_response :ok
    json = JSON.parse(response.body)
    # PaginatedResponse wraps sorted_by_campaigns result: {data: {result: [...]}, page:, ...}
    assert json.key?("data"), "must return data key"
    assert json.key?("total_entries"), "must return total_entries for pagination"
    assert json.key?("page"), "must return page for pagination"

    campaigns_data = json["data"]
    results = campaigns_data.is_a?(Hash) ? campaigns_data["result"] : campaigns_data
    assert_kind_of Array, results, "campaigns result must be an array"

    campaign_names = results.map { |c| c.dig("campaign", "name") }
    assert_includes campaign_names, @campaign.name, "fixture campaign must appear in results"
  end

  # --- Update Campaign ---

  test "update campaign persists name change" do
    patch "#{API_PREFIX}/projects/#{@project.id}/campaigns/#{@campaign.id}",
      params: { name: "Updated Campaign Name" },
      headers: @headers
    assert_response :ok
    json = JSON.parse(response.body)
    assert_equal "Updated Campaign Name", json["campaign"]["name"]

    @campaign.reload
    assert_equal "Updated Campaign Name", @campaign.name, "name must be persisted in DB"
  end

  # --- Archive Campaign ---

  test "archive campaign sets archived flag in DB" do
    delete "#{API_PREFIX}/projects/#{@project.id}/campaigns/#{@campaign.id}",
      headers: @headers
    assert_response :ok
    json = JSON.parse(response.body)
    assert json["campaign"]["archived"], "response must show campaign as archived"

    @campaign.reload
    assert @campaign.archived, "campaign must be archived in DB"
  end

  # --- Search V2 ---

  test "search_v2 returns serialized campaigns with has_links and stats, without project_id or updated_at" do
    post "#{API_PREFIX}/projects/#{@project.id}/campaigns/search_v2",
      params: { archived: "false", page: 1, sort_by: "created_at", ascendent: "false" },
      headers: @headers
    assert_response :ok
    json = JSON.parse(response.body)

    assert json.key?("data"), "must return data key"
    assert json.key?("total_entries"), "must return pagination"
    assert_kind_of Array, json["data"]

    campaign = json["data"].find { |c| c["name"] == @campaign.name }
    assert_not_nil campaign, "fixture campaign must appear in v2 results"

    # Serializer fields present
    assert campaign.key?("id"), "must include id"
    assert campaign.key?("name"), "must include name"
    assert campaign.key?("archived"), "must include archived"
    assert campaign.key?("created_at"), "must include created_at"
    assert campaign.key?("has_links"), "must include has_links"

    # Internal columns excluded
    assert_not campaign.key?("project_id"), "must not expose project_id"
    assert_not campaign.key?("updated_at"), "must not expose updated_at"

    # Aggregate stats passed through
    assert campaign.key?("total_views"), "must include total_views stat"
    assert campaign.key?("total_opens"), "must include total_opens stat"
  end

  # --- Cross-Tenant Access ---

  test "access another instance's campaigns returns 403 with no data leak" do
    post "#{API_PREFIX}/projects/#{@project_two.id}/campaigns/search",
      params: { archived: "false" },
      headers: @headers
    assert_response :forbidden
    json = JSON.parse(response.body)
    assert_equal "Forbidden", json["error"]
    assert_not json.key?("data"), "403 must not leak campaign data"
  end
end
