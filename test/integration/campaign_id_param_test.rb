require "test_helper"
require_relative "auth_test_helper"
require_relative "mcp_auth_test_helper"
require "sidekiq/testing"

class CampaignIdParamTest < ActionDispatch::IntegrationTest
  include AuthTestHelper
  include McpAuthTestHelper

  fixtures :instances, :users, :instance_roles, :projects, :domains,
           :redirect_configs, :links, :campaigns

  SEARCH_BODY = {
    active: true, sdk: false, ascending: false, page: 1, per_page: 25,
    start_date: "2026-01-01T00:00:00.000Z", sort_by: "updated_at"
  }.freeze

  setup do
    @admin_user = users(:admin_user)
    @project = projects(:one)
    @campaign = campaigns(:one)
    @headers = doorkeeper_headers_for(@admin_user)
    @json_headers = @headers.merge("CONTENT_TYPE" => "application/json")
    @mcp_headers = create_mcp_headers_for(@admin_user)
  end

  test "export accepts a JSON integer campaign_id" do
    Sidekiq::Testing.fake! do
      ExportLinkDataJob.jobs.clear
      post "#{API_PREFIX}/projects/#{@project.id}/exports/links",
        params: { campaign_id: @campaign.id }.to_json, headers: @json_headers
      assert_response :accepted
      assert_equal @campaign.id, ExportLinkDataJob.jobs.first["args"][1]["campaign_id"]
    end
  end

  test "export accepts a string campaign_id" do
    Sidekiq::Testing.fake! do
      ExportLinkDataJob.jobs.clear
      post "#{API_PREFIX}/projects/#{@project.id}/exports/links",
        params: { campaign_id: @campaign.id.to_s }, headers: @headers
      assert_response :accepted
      assert_equal @campaign.id, ExportLinkDataJob.jobs.first["args"][1]["campaign_id"]
    end
  end

  test "export rejects a hex campaign_id" do
    Sidekiq::Testing.fake! do
      ExportLinkDataJob.jobs.clear
      post "#{API_PREFIX}/projects/#{@project.id}/exports/links",
        params: { campaign_id: "0x1f" }, headers: @headers
      assert_response :bad_request
      assert_equal 0, ExportLinkDataJob.jobs.size
    end
  end

  test "create link accepts a JSON integer campaign_id" do
    post "#{API_PREFIX}/projects/#{@project.id}/links",
      params: { title: "Int Campaign", path: "int-campaign-path", campaign_id: @campaign.id }.to_json,
      headers: @json_headers
    assert_response :ok
    assert_equal @campaign.id, Link.find_by(path: "int-campaign-path").campaign_id
  end

  test "create link accepts a leading-zero campaign_id as decimal" do
    post "#{API_PREFIX}/projects/#{@project.id}/links",
      params: { title: "Zero Campaign", path: "zero-campaign-path", campaign_id: "0#{@campaign.id}" },
      headers: @headers
    assert_response :ok
    assert_equal @campaign.id, Link.find_by(path: "zero-campaign-path").campaign_id
  end

  test "create link rejects a hex campaign_id" do
    assert_no_difference "Link.count" do
      post "#{API_PREFIX}/projects/#{@project.id}/links",
        params: { title: "Hex Campaign", path: "hex-campaign-path", campaign_id: "0x1f" },
        headers: @headers
    end
    assert_response :bad_request
  end

  test "link search rejects a malformed campaign_id" do
    post "#{API_PREFIX}/projects/#{@project.id}/links/search_v2",
      params: SEARCH_BODY.merge(campaign_id: "not_an_integer"), headers: @headers, as: :json
    assert_response :bad_request
    assert_equal "campaign_id must be an integer", JSON.parse(response.body)["error"]
  end

  test "link search accepts a JSON integer campaign_id" do
    post "#{API_PREFIX}/projects/#{@project.id}/links/search_v2",
      params: SEARCH_BODY.merge(campaign_id: @campaign.id), headers: @headers, as: :json
    assert_response :ok
  end

  test "mcp create link rejects a malformed campaign_id" do
    assert_no_difference "Link.count" do
      post "#{MCP_PREFIX}/links",
        params: { project_id: @project.hashid, name: "Mcp Campaign", title: "Mcp Campaign",
                  path: "mcp-campaign-path", campaign_id: "not_an_integer" },
        headers: @mcp_headers
    end
    assert_response :bad_request
    assert_equal "campaign_id must be an integer", JSON.parse(response.body)["error"]
  end

  test "mcp create link accepts a JSON integer campaign_id" do
    post "#{MCP_PREFIX}/links",
      params: { project_id: @project.hashid, name: "Mcp Int", title: "Mcp Int",
                path: "mcp-int-path", campaign_id: @campaign.id },
      headers: @mcp_headers, as: :json
    assert_response :created
    assert_equal @campaign.id, Link.find_by(path: "mcp-int-path").campaign_id
  end

  test "malformed decimals are rejected across every campaign_id surface" do
    ["1_0", "+1", "0d10", "-5", "12.5", "0x1f"].each do |bad|
      post "#{API_PREFIX}/projects/#{@project.id}/links",
        params: { title: "Bad", path: "bad-#{bad}", campaign_id: bad }, headers: @headers
      assert_response :bad_request, "create_link must reject #{bad.inspect}"

      post "#{API_PREFIX}/projects/#{@project.id}/exports/links",
        params: { campaign_id: bad }, headers: @headers
      assert_response :bad_request, "export must reject #{bad.inspect}"

      post "#{API_PREFIX}/projects/#{@project.id}/events/overview",
        params: SEARCH_BODY.merge(campaign_id: bad), headers: @headers, as: :json
      assert_response :bad_request, "events overview must reject #{bad.inspect}"
    end
  end

  test "leading zeros stay decimal across export, events and mcp" do
    Sidekiq::Testing.fake! do
      ExportLinkDataJob.jobs.clear
      post "#{API_PREFIX}/projects/#{@project.id}/exports/links",
        params: { campaign_id: "0#{@campaign.id}" }, headers: @headers
      assert_response :accepted
      assert_equal @campaign.id, ExportLinkDataJob.jobs.first["args"][1]["campaign_id"]
    end

    post "#{API_PREFIX}/projects/#{@project.id}/events/overview",
      params: SEARCH_BODY.merge(campaign_id: "0#{@campaign.id}"), headers: @headers, as: :json
    assert_response :ok

    post "#{MCP_PREFIX}/links",
      params: { project_id: @project.hashid, name: "Mcp Zero", title: "Mcp Zero",
                path: "mcp-zero-path", campaign_id: "0#{@campaign.id}" },
      headers: @mcp_headers, as: :json
    assert_response :created
    assert_equal @campaign.id, Link.find_by(path: "mcp-zero-path").campaign_id
  end

  test "mcp search and update reject a malformed campaign_id" do
    post "#{MCP_PREFIX}/links/search",
      params: { project_id: @project.hashid, campaign_id: "not_an_integer" },
      headers: @mcp_headers, as: :json
    assert_response :bad_request

    patch "#{MCP_PREFIX}/links/#{links(:basic_link).id}",
      params: { project_id: @project.hashid, campaign_id: "not_an_integer" },
      headers: @mcp_headers, as: :json
    assert_response :bad_request
  end

  test "missing and foreign resources still 404 rather than 400" do
    post "#{API_PREFIX}/projects/#{@project.id}/exports/links",
      params: { campaign_id: campaigns(:two).id }, headers: @headers
    assert_response :not_found
    assert_equal "Campaign not found", JSON.parse(response.body)["error"]

    delete "#{API_PREFIX}/projects/#{@project.id}/links/999999", headers: @headers
    assert_response :not_found

    patch "#{MCP_PREFIX}/links/999999",
      params: { project_id: @project.hashid, campaign_id: "not_an_integer" },
      headers: @mcp_headers, as: :json
    assert_response :not_found
  end

  test "events search still returns the Rails shape when a required param is missing" do
    post "#{API_PREFIX}/projects/#{@project.id}/events/search",
      params: { campaign_id: @campaign.id }, headers: @headers
    assert_response :bad_request
    assert_equal 400, JSON.parse(response.body)["status"]
  end

  test "events billing ignores campaign_id instead of validating it" do
    post "#{API_PREFIX}/instances/#{instances(:one).id}/events/billing",
      params: SEARCH_BODY.merge(campaign_id: "not_an_integer"), headers: @headers, as: :json
    assert_response :ok
  end

  test "events overview rejects a malformed campaign_id" do

    post "#{API_PREFIX}/projects/#{@project.id}/events/overview",
      params: SEARCH_BODY.merge(campaign_id: "not_an_integer"), headers: @headers, as: :json
    assert_response :bad_request
  end
end
