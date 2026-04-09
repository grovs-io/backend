require "test_helper"
require_relative "../mcp_auth_test_helper"

class McpCampaignsTest < ActionDispatch::IntegrationTest
  include McpAuthTestHelper

  fixtures :instances, :users, :instance_roles, :projects, :domains,
           :redirect_configs, :links, :campaigns, :link_daily_statistics

  setup do
    @admin_user = users(:admin_user)
    @member_user = users(:member_user)
    @instance = instances(:one)
    @project = projects(:one)
    @campaign = campaigns(:one)
    @campaign_link = links(:campaign_link)
    # Assign campaign_link to campaign :one (not done in fixture to avoid FK issues
    # in tests that load :links without :campaigns)
    @campaign_link.update_column(:campaign_id, @campaign.id)
    @admin_headers = create_mcp_headers_for(@admin_user)
    @member_headers = create_mcp_headers_for(@member_user)
  end

  # ==========================================================================
  # Create Campaign — full output schema
  # ==========================================================================

  test "create_campaign returns full campaign schema" do
    assert_difference "Campaign.count", 1 do
      post "#{MCP_PREFIX}/campaigns",
        params: { project_id: @project.hashid, name: "New MCP Campaign" },
        headers: @admin_headers
    end
    assert_response :created
    c = json_response["campaign"]

    # Every CampaignSerializer field must be present and correct
    assert_kind_of Integer, c["id"]
    assert_equal "New MCP Campaign", c["name"]
    assert_equal false, c["archived"]
    assert_not_nil c["created_at"]
    assert_equal false, c["has_links"], "newly created campaign has no links"

    # No extra unexpected keys leak (e.g. project_id, updated_at)
    expected_keys = %w[id name archived created_at has_links]
    assert_equal expected_keys.sort, c.keys.sort,
      "response keys should match CampaignSerializer exactly"
  end

  test "create_campaign without redirect_config returns 400 with service error" do
    @project.redirect_config.destroy!

    assert_no_difference "Campaign.count" do
      post "#{MCP_PREFIX}/campaigns",
        params: { project_id: @project.hashid, name: "No Config" },
        headers: @admin_headers
    end
    assert_response :bad_request
    assert_match(/redirect configuration/i, json_response["error"])
  end

  test "create_campaign forbidden for non-member project" do
    assert_no_difference "Campaign.count" do
      post "#{MCP_PREFIX}/campaigns",
        params: { project_id: projects(:two).hashid, name: "Forbidden" },
        headers: @admin_headers
    end
    assert_response :forbidden
    assert_equal "Forbidden", json_response["error"]
  end

  # ==========================================================================
  # Search Campaigns — full output schema
  # ==========================================================================

  test "search_campaigns returns full campaign + metrics schema" do
    post "#{MCP_PREFIX}/campaigns/search",
      params: {
        project_id: @project.hashid,
        start_date: "2026-03-01",
        end_date: "2026-03-02"
      },
      headers: @admin_headers
    assert_response :ok
    json = json_response

    # ── Meta schema ──
    meta = json["meta"]
    assert_equal 1, meta["page"]
    assert_kind_of Integer, meta["per_page"]
    assert_kind_of Integer, meta["total_pages"]
    assert_equal 2, meta["total_entries"]
    expected_meta_keys = %w[page per_page total_pages total_entries]
    assert_equal expected_meta_keys.sort, meta.keys.sort,
      "meta keys should match pagination schema exactly"

    # ── Campaign schema — every serializer field + every aggregate ──
    assert_equal 2, json["campaigns"].length
    spring = json["campaigns"].find { |c| c["name"] == "Spring 2026 Campaign" }
    assert_not_nil spring

    # CampaignSerializer attributes
    assert_kind_of Integer, spring["id"]
    assert_equal "Spring 2026 Campaign", spring["name"]
    assert_equal false, spring["archived"]
    assert_not_nil spring["created_at"]
    assert_equal true, spring["has_links"]

    # All 9 aggregate metrics from CampaignStatisticsQuery (stat_campaign_link_day1)
    assert_equal 150,  spring["total_views"]
    assert_equal 70,   spring["total_opens"]
    assert_equal 15,   spring["total_installs"]
    assert_equal 3,    spring["total_reinstalls"]
    assert_equal 6000, spring["total_time_spent"]
    assert_equal 2,    spring["total_reactivations"]
    assert_equal 40,   spring["total_app_opens"]
    assert_equal 5,    spring["total_user_referred"]
    assert_equal 1500, spring["total_revenue"]

    # Verify no metrics are missing from the schema
    expected_campaign_keys = %w[
      id name archived created_at has_links
      total_views total_opens total_installs total_reinstalls
      total_time_spent total_reactivations total_app_opens
      total_user_referred total_revenue
    ]
    assert_equal expected_campaign_keys.sort, spring.keys.sort,
      "campaign keys should include all serializer attrs + all SQL aggregates"

    # Campaign with no links has zeroed metrics
    archived_c = json["campaigns"].find { |c| c["name"] == "Archived Campaign" }
    assert_not_nil archived_c
    assert_equal 0, archived_c["total_views"]
    assert_equal 0, archived_c["total_revenue"]
    assert_equal false, archived_c["has_links"], "archived campaign has no links"
  end

  test "search_campaigns filters by term" do
    post "#{MCP_PREFIX}/campaigns/search",
      params: { project_id: @project.hashid, term: "Spring" },
      headers: @admin_headers
    assert_response :ok
    json = json_response
    assert_equal 1, json["campaigns"].length
    assert_equal "Spring 2026 Campaign", json["campaigns"].first["name"]
  end

  test "search_campaigns paginates with per_page and page" do
    post "#{MCP_PREFIX}/campaigns/search",
      params: { project_id: @project.hashid, per_page: 1, page: 1 },
      headers: @admin_headers
    assert_response :ok
    page1 = json_response
    assert_equal 1, page1["campaigns"].length
    assert_equal 1, page1["meta"]["page"]
    assert_equal 2, page1["meta"]["total_pages"]
    assert_equal 2, page1["meta"]["total_entries"]

    post "#{MCP_PREFIX}/campaigns/search",
      params: { project_id: @project.hashid, per_page: 1, page: 2 },
      headers: @admin_headers
    assert_response :ok
    page2 = json_response
    assert_equal 1, page2["campaigns"].length
    assert_equal 2, page2["meta"]["page"]
    assert_not_equal page1["campaigns"].first["name"], page2["campaigns"].first["name"]
  end

  test "search_campaigns filters by archived status" do
    # Only non-archived
    post "#{MCP_PREFIX}/campaigns/search",
      params: { project_id: @project.hashid, archived: false },
      headers: @admin_headers
    assert_response :ok
    json = json_response
    assert_equal 1, json["campaigns"].length
    assert_equal "Spring 2026 Campaign", json["campaigns"].first["name"]
    assert json["campaigns"].all? { |c| c["archived"] == false }

    # Only archived
    post "#{MCP_PREFIX}/campaigns/search",
      params: { project_id: @project.hashid, archived: true },
      headers: @admin_headers
    assert_response :ok
    json = json_response
    assert_equal 1, json["campaigns"].length
    assert_equal "Archived Campaign", json["campaigns"].first["name"]
    assert json["campaigns"].all? { |c| c["archived"] == true }
  end

  # ==========================================================================
  # Archive Campaign — full output schema
  # ==========================================================================

  test "archive_campaign returns full schema and deactivates links" do
    assert @campaign_link.active, "campaign_link should start active"

    delete "#{MCP_PREFIX}/campaigns/#{@campaign.id}",
      params: { project_id: @project.hashid },
      headers: @admin_headers
    assert_response :ok
    c = json_response["campaign"]

    # Full CampaignSerializer output
    assert_equal @campaign.id, c["id"]
    assert_equal "Spring 2026 Campaign", c["name"]
    assert_equal true, c["archived"]
    assert_not_nil c["created_at"]
    # has_links: archived campaigns check links.exists? (not .active.exists?)
    assert_equal true, c["has_links"], "campaign still has links (archived check uses exists?)"

    expected_keys = %w[id name archived created_at has_links]
    assert_equal expected_keys.sort, c.keys.sort

    # Side effects: verify DB state
    @campaign.reload
    assert @campaign.archived

    @campaign_link.reload
    assert_not @campaign_link.active, "links should be deactivated"
  end

  test "archive_campaign on already-archived campaign is idempotent" do
    archived = campaigns(:archived_campaign)
    delete "#{MCP_PREFIX}/campaigns/#{archived.id}",
      params: { project_id: @project.hashid },
      headers: @admin_headers
    assert_response :ok
    assert_equal true, json_response["campaign"]["archived"]
  end

  test "archive_campaign returns 404 for nonexistent campaign" do
    delete "#{MCP_PREFIX}/campaigns/999999999",
      params: { project_id: @project.hashid },
      headers: @admin_headers
    assert_response :not_found
    assert_equal "Campaign not found", json_response["error"]
  end

  test "archive_campaign returns 404 for campaign from wrong project" do
    delete "#{MCP_PREFIX}/campaigns/#{campaigns(:two).id}",
      params: { project_id: @project.hashid },
      headers: @admin_headers
    assert_response :not_found
    assert_equal "Campaign not found", json_response["error"]
  end

  # ==========================================================================
  # Campaign + Link Integration
  # ==========================================================================

  test "create_link with campaign_id associates link and shows in campaign has_links" do
    assert_difference "Link.count", 1 do
      post "#{MCP_PREFIX}/links",
        params: {
          project_id: @project.hashid,
          name: "Linked to Campaign",
          path: "campaign-associated-link",
          campaign_id: @campaign.id
        },
        headers: @admin_headers
    end
    assert_response :created
    created = Link.find(json_response["link"]["id"])
    assert_equal @campaign.id, created.campaign_id

    # Verify campaign now reports has_links via search
    post "#{MCP_PREFIX}/campaigns/search",
      params: { project_id: @project.hashid, term: "Spring" },
      headers: @admin_headers
    assert_equal true, json_response["campaigns"].first["has_links"]
  end

  test "update_link can assign and reassign campaign_id" do
    link = links(:basic_link)
    assert_nil link.campaign_id

    # Assign to campaign
    patch "#{MCP_PREFIX}/links/#{link.id}",
      params: { project_id: @project.hashid, campaign_id: @campaign.id },
      headers: @admin_headers
    assert_response :ok
    assert_equal @campaign.id, link.reload.campaign_id

    # Reassign to a different campaign
    new_campaign = Campaign.create!(name: "New One", project: @project)
    patch "#{MCP_PREFIX}/links/#{link.id}",
      params: { project_id: @project.hashid, campaign_id: new_campaign.id },
      headers: @admin_headers
    assert_response :ok
    assert_equal new_campaign.id, link.reload.campaign_id
  end
end
