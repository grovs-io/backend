# frozen_string_literal: true

require "test_helper"
require_relative "../mcp_auth_test_helper"

class McpProjectDashboardsTest < ActionDispatch::IntegrationTest
  include McpAuthTestHelper

  fixtures :instances, :users, :instance_roles, :projects, :dashboards, :dashboard_widgets

  setup do
    @project = projects(:one)
    @headers = create_mcp_headers_for(users(:member_user))
    @base = "#{MCP_PREFIX}/projects/#{@project.hashid}/dashboards"
  end

  def widget(title, **extra)
    { title: title, viz: "bar", size: "md", query: { metric: "installs" } }.merge(extra)
  end

  test "list returns the project's dashboards with widgets" do
    post "#{@base}/list", headers: @headers, as: :json
    assert_response :ok
    assert_equal ["Growth"], json_response["dashboards"].map { |d| d["name"] }
    assert_equal ["Installs by country", "Opens"], json_response["dashboards"][0]["widgets"].map { |w| w["title"] }
  end

  test "create builds the dashboard and its widgets, keeping filters out of the query" do
    ios = [{ field: "platform", operator: "is", value: "ios" }]
    assert_difference -> { Dashboard.count } => 1, -> { DashboardWidget.count } => 2 do
      post @base, params: { name: "Onboarding", widgets: [
        widget("Installs by country", query: { metric: "installs", group_by: "country", compare: true }, filters: ios),
        widget("Opens", viz: "line", query: { metric: "opens", granularity: "day" })
      ] }, headers: @headers, as: :json
    end
    assert_response :ok
    saved = Dashboard.find(json_response["dashboard"]["id"]).widgets.order(:position)
    assert_equal %w[metric metric], saved.map(&:kind)
    assert_equal({ "metric" => "installs", "limit" => 10, "compare" => true, "group_by" => "country" }, saved[0].query)
    assert_equal [{ "field" => "platform", "operator" => "is", "value" => "ios" }], saved[0].filters
    assert_equal [], saved[1].filters
  end

  test "an invalid widget rolls back the whole dashboard" do
    assert_no_difference -> { Dashboard.count } do
      post @base, params: { name: "Broken", widgets: [widget("Fine"), widget("Bad", query: { metric: "nope" })] },
                  headers: @headers, as: :json
    end
    assert_response :unprocessable_entity
    assert_match(/widget 2/, json_response["error"])
  end

  test "a widget grouped by an identity property is refused like query_metric" do
    assert_no_difference -> { Dashboard.count } do
      post @base, params: { name: "Leaky", widgets: [widget("W", query: { metric: "installs", group_by: "properties.email" })] },
                  headers: @headers, as: :json
    end
    assert_response :unprocessable_entity
    assert_match(/properties.email is not available/, json_response["error"])
  end

  test "kind and panel cannot be smuggled in" do
    post @base, params: { name: "Panels", widgets: [widget("P", kind: "panel", panel: "kpis_revenue")] }, headers: @headers, as: :json
    assert_response :ok
    assert_equal "metric", DashboardWidget.find(json_response["dashboard"]["widgets"][0]["id"]).kind
  end

  test "widgets must be a list of objects and at most the per-dashboard cap" do
    post @base, params: { name: "X", widgets: "nope" }, headers: @headers, as: :json
    assert_response :unprocessable_entity
    post @base, params: { name: "X", widgets: Array.new(21) { |i| widget("W#{i}") } }, headers: @headers, as: :json
    assert_response :unprocessable_entity
  end

  test "the per-project dashboard cap holds" do
    (Dashboard::MAX_PER_PROJECT - @project.dashboards.count).times { |i| @project.dashboards.create!(name: "D#{i}") }
    assert_no_difference -> { Dashboard.count } do
      post @base, params: { name: "One too many" }, headers: @headers, as: :json
    end
    assert_response :unprocessable_entity
    assert_match(/at most/, json_response["error"])
  end

  test "non-members are refused" do
    post "#{@base}/list", headers: create_mcp_headers_for(users(:oauth_user)), as: :json
    assert_response :forbidden
  end
end
