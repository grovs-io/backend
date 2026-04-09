require "test_helper"
require_relative "../mcp_auth_test_helper"

class McpAnalyticsTest < ActionDispatch::IntegrationTest
  include McpAuthTestHelper

  fixtures :instances, :users, :instance_roles, :projects, :domains,
           :links, :devices, :link_daily_statistics, :daily_project_metrics

  setup do
    @admin_user = users(:admin_user)
    @member_user = users(:member_user)
    @instance = instances(:one)
    @project = projects(:one)
    @link = links(:basic_link)
    @admin_headers = create_mcp_headers_for(@admin_user)
    @member_headers = create_mcp_headers_for(@member_user)
  end

  # ==========================================================================
  # Link Stats
  # ==========================================================================

  test "link_stats returns per-event metrics for a link with events" do
    # Create events with link_id so EventMetricsQuery finds them
    Event.create!(project: @project, device: devices(:ios_device), link: @link,
                  event: "view", platform: "ios", created_at: "2026-03-01 10:00:00")
    Event.create!(project: @project, device: devices(:ios_device), link: @link,
                  event: "view", platform: "ios", created_at: "2026-03-01 10:30:00")
    Event.create!(project: @project, device: devices(:ios_device), link: @link,
                  event: "open", platform: "ios", created_at: "2026-03-01 11:00:00")
    Event.create!(project: @project, device: devices(:android_device), link: @link,
                  event: "install", platform: "android", created_at: "2026-03-01 12:00:00")

    headers = @admin_headers
    post "#{MCP_PREFIX}/analytics/link",
      params: {
        project_id: @project.hashid,
        path: @link.path,
        start_date: "2026-03-01",
        end_date: "2026-03-01"
      },
      headers: headers
    assert_response :ok
    json = json_response
    assert_equal @link.path, json["link_path"]

    link_metrics = json["metrics"][@link.id.to_s]
    assert_not_nil link_metrics, "should have metrics keyed by link ID"
    assert_equal 2, link_metrics["view"]
    assert_equal 1, link_metrics["open"]
    assert_equal 1, link_metrics["install"]
    assert_equal 0, link_metrics["reinstall"]
    assert_equal 0, link_metrics["reactivation"]
    assert link_metrics.key?("avg_engagement_time"), "should include avg_engagement_time"
  end

  test "link_stats excludes events outside the date range" do
    # In-range event
    Event.create!(project: @project, device: devices(:ios_device), link: @link,
                  event: "view", platform: "ios", created_at: "2026-03-01 10:00:00")
    # Out-of-range event (should be excluded)
    Event.create!(project: @project, device: devices(:ios_device), link: @link,
                  event: "view", platform: "ios", created_at: "2026-03-02 10:00:00")

    headers = @admin_headers
    post "#{MCP_PREFIX}/analytics/link",
      params: {
        project_id: @project.hashid,
        path: @link.path,
        start_date: "2026-03-01",
        end_date: "2026-03-01"
      },
      headers: headers
    assert_response :ok
    json = json_response

    link_metrics = json["metrics"][@link.id.to_s]
    assert_equal 1, link_metrics["view"], "should only count the in-range event"
  end

  test "link_stats returns 404 for nonexistent link" do
    headers = @admin_headers
    post "#{MCP_PREFIX}/analytics/link",
      params: {
        project_id: @project.hashid,
        path: "nonexistent-link-path"
      },
      headers: headers
    assert_response :not_found
    json = json_response
    assert_equal "Link not found", json["error"]
  end

  test "link_stats requires project_id" do
    headers = @admin_headers
    post "#{MCP_PREFIX}/analytics/link",
      params: { path: @link.path },
      headers: headers
    assert_response :bad_request
  end

  test "link_stats returns 404 when project has no domain" do
    # Create an instance with a project that has no domain
    service = InstanceProvisioningService.new(current_user: @admin_user)
    instance = service.create(name: "No Domain Test")
    # Remove the auto-created domain
    instance.production.domain&.destroy

    headers = @admin_headers
    post "#{MCP_PREFIX}/analytics/link",
      params: {
        project_id: instance.production.hashid,
        path: "anything"
      },
      headers: headers
    assert_response :not_found
    json = json_response
    assert_equal "Project has no domain configured", json["error"]
  end

  test "link_stats forbidden for non-member" do
    headers = @admin_headers
    post "#{MCP_PREFIX}/analytics/link",
      params: {
        project_id: projects(:two).hashid,
        path: "second-path"
      },
      headers: headers
    assert_response :forbidden
  end

  # ==========================================================================
  # Project Metrics
  # ==========================================================================

  test "project_metrics returns aggregated metrics from daily_project_metrics" do
    headers = @admin_headers
    # Sums metric_day1 (ios) + metric_day1_android from daily_project_metrics.yml, both on 2026-02-15
    post "#{MCP_PREFIX}/analytics/overview",
      params: {
        project_id: @project.hashid,
        start_date: "2026-02-14",
        end_date: "2026-02-16"
      },
      headers: headers
    assert_response :ok
    json = json_response

    current = json["metrics"]["current"]
    # ios(100) + android(40)
    assert_equal 140, current["views"]
    # ios(10) + android(5)
    assert_equal 15, current["installs"]
    # ios(50) + android(20)
    assert_equal 70, current["opens"]
    # ios(2) + android(1)
    assert_equal 3, current["reinstalls"]
    # ios(80) + android(30)
    assert_equal 110, current["link_views"]
    # ios(30) + android(10)
    assert_equal 40, current["app_opens"]
    # ios(3) + android(1)
    assert_equal 4, current["referred_users"]
    # ios(7) + android(3)
    assert_equal 10, current["organic_users"]
    # ios(10) + android(4)
    assert_equal 14, current["new_users"]
    # ios(999) + android(500)
    assert_equal 1499, current["revenue"]
    # ios(5) + android(2)
    assert_equal 7, current["units_sold"]
    # ios(1) + android(0)
    assert_equal 1, current["cancellations"]
    # ios(3) + android(1)
    assert_equal 4, current["first_time_purchases"]

    # Previous period (Feb 11-13) has no data — all zeros
    previous = json["metrics"]["previous"]
    assert_equal 0, previous["views"]
    assert_equal 0, previous["installs"]
    assert_equal 0, previous["revenue"]
  end

  test "project_metrics filters by platform when provided" do
    headers = @admin_headers
    # Request ios only — should exclude android fixture data
    post "#{MCP_PREFIX}/analytics/overview",
      params: {
        project_id: @project.hashid,
        start_date: "2026-02-14",
        end_date: "2026-02-16",
        platform: "ios"
      },
      headers: headers
    assert_response :ok
    json = json_response

    current = json["metrics"]["current"]
    assert_equal 100, current["views"], "should only include ios views"
    assert_equal 10, current["installs"], "should only include ios installs"
    assert_equal 999, current["revenue"], "should only include ios revenue"
    assert_equal 50, current["opens"], "should only include ios opens"
  end

  test "project_metrics with malformed dates falls back to defaults" do
    headers = @admin_headers
    post "#{MCP_PREFIX}/analytics/overview",
      params: {
        project_id: @project.hashid,
        start_date: "garbage",
        end_date: "not-a-date"
      },
      headers: headers
    assert_response :ok
    json = json_response
    assert json["metrics"]["current"].present?, "should return metrics using default date range"
  end

  test "project_metrics forbidden for non-member" do
    headers = @admin_headers
    post "#{MCP_PREFIX}/analytics/overview",
      params: { project_id: projects(:two).hashid },
      headers: headers
    assert_response :forbidden
  end

  test "project_metrics requires project_id" do
    headers = @admin_headers
    post "#{MCP_PREFIX}/analytics/overview",
      params: {},
      headers: headers
    assert_response :bad_request
  end

  # ==========================================================================
  # Top Links
  # ==========================================================================

  test "top_links returns links sorted by installs with aggregated metrics" do
    headers = @admin_headers
    # link_daily_statistics: basic_link (stat_day1 + stat_day2) and no_custom_redirect_link (stat_standard_link_day1)
    post "#{MCP_PREFIX}/analytics/top_links",
      params: {
        project_id: @project.hashid,
        start_date: "2026-03-01",
        end_date: "2026-03-02"
      },
      headers: headers
    assert_response :ok
    json = json_response

    assert_equal 3, json["links"].length, "basic_link, standard-path, and campaign-link-path all have stats"
    # basic_link aggregates stat_day1 + stat_day2 from link_daily_statistics.yml
    # More installs (30) than standard-path (2) — should be sorted first
    top_link = json["links"].first
    assert_equal "test-path", top_link["path"]
    assert_equal 300, top_link["views"]            # 100 + 200
    assert_equal 130, top_link["opens"]             # 50 + 80
    assert_equal 30, top_link["installs"]           # 10 + 20
    assert_equal 7, top_link["reinstalls"]          # 2 + 5
    assert_equal 4, top_link["reactivations"]       # 1 + 3
    assert_equal 13_000, top_link["time_spent"]     # 5000 + 8000
  end

  test "top_links respects limit parameter" do
    headers = @admin_headers
    # Both basic_link and no_custom_redirect_link have stats in this range
    post "#{MCP_PREFIX}/analytics/top_links",
      params: {
        project_id: @project.hashid,
        start_date: "2026-03-01",
        end_date: "2026-03-02",
        limit: 1
      },
      headers: headers
    assert_response :ok
    json = json_response

    assert_equal 1, json["links"].length, "limit: 1 should return only the top link"
    assert_equal "test-path", json["links"].first["path"]
  end

  test "top_links returns empty array when date range has no data" do
    headers = @admin_headers
    post "#{MCP_PREFIX}/analytics/top_links",
      params: {
        project_id: @project.hashid,
        start_date: "2026-01-01",
        end_date: "2026-01-02",
        limit: 5
      },
      headers: headers
    assert_response :ok
    json = json_response
    assert_equal [], json["links"]
  end

  test "top_links forbidden for non-member" do
    headers = @admin_headers
    post "#{MCP_PREFIX}/analytics/top_links",
      params: { project_id: projects(:two).hashid },
      headers: headers
    assert_response :forbidden
  end

  test "top_links requires project_id" do
    headers = @admin_headers
    post "#{MCP_PREFIX}/analytics/top_links",
      params: {},
      headers: headers
    assert_response :bad_request
  end

  # ==========================================================================
  # Member User Access
  # ==========================================================================

  test "member_user can access project_metrics" do
    post "#{MCP_PREFIX}/analytics/overview",
      params: { project_id: @project.hashid, start_date: "2026-02-14", end_date: "2026-02-16" },
      headers: @member_headers
    assert_response :ok
  end

  test "member_user can access link_stats" do
    post "#{MCP_PREFIX}/analytics/link",
      params: { project_id: @project.hashid, path: @link.path, start_date: "2026-03-01", end_date: "2026-03-01" },
      headers: @member_headers
    assert_response :ok
  end

  test "member_user can access top_links" do
    post "#{MCP_PREFIX}/analytics/top_links",
      params: { project_id: @project.hashid, start_date: "2026-03-01", end_date: "2026-03-02" },
      headers: @member_headers
    assert_response :ok
  end
end
