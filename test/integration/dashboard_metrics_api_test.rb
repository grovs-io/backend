require "test_helper"
require_relative "auth_test_helper"

class DashboardMetricsApiTest < ActionDispatch::IntegrationTest
  include AuthTestHelper

  fixtures :instances, :users, :instance_roles, :projects, :domains,
           :redirect_configs, :links, :daily_project_metrics,
           :link_daily_statistics

  setup do
    @admin_user = users(:admin_user)
    @project = projects(:one)
    @project_two = projects(:two)
    @link = links(:basic_link)
    @headers = doorkeeper_headers_for(@admin_user)
  end

  # --- Unauthenticated ---

  test "metrics overview without auth returns 401 with no data" do
    post "#{API_PREFIX}/projects/#{@project.id}/dashboard/metrics_overview", headers: api_headers
    assert_response :unauthorized
    assert_no_match(/"metrics"/, response.body, "401 must not leak metrics data")
  end

  # --- Metrics Overview ---

  test "metrics overview returns correct aggregate values from fixture data" do
    # Query only 2026-02-15 so we get exactly metric_day1 fixture values
    post "#{API_PREFIX}/projects/#{@project.id}/dashboard/metrics_overview",
      params: { start_date: "2026-02-15", end_date: "2026-02-15" },
      headers: @headers
    assert_response :ok
    json = JSON.parse(response.body)
    current = json["metrics"]["current"]

    # These must match daily_project_metrics.yml metric_day1 exactly
    assert_equal 100, current["views"], "views must match fixture metric_day1"
    assert_equal 10, current["installs"], "installs must match fixture metric_day1"
    assert_equal 50, current["opens"], "opens must match fixture metric_day1"
    assert_equal 2, current["reinstalls"], "reinstalls must match fixture metric_day1"
    assert_equal 80, current["link_views"], "link_views must match fixture metric_day1"
    assert_equal 10, current["new_users"], "new_users must match fixture metric_day1"
    assert_equal 30, current["app_opens"], "app_opens must match fixture metric_day1"
    assert_equal 999, current["revenue"], "revenue must match fixture metric_day1"
    assert_equal 5, current["units_sold"], "units_sold must match fixture metric_day1"
    assert_equal 1, current["cancellations"], "cancellations must match fixture metric_day1"
    assert_equal 3, current["first_time_purchases"], "first_time_purchases must match fixture metric_day1"
    assert_equal 7, current["organic_users"], "organic_users must match fixture metric_day1"
    assert_equal 3, current["referred_users"], "referred_users must match fixture metric_day1"

    # Previous period should have zero values (no data before 2026-02-15)
    previous = json["metrics"]["previous"]
    assert_equal 0, previous["views"], "previous period views must be 0"
    assert_equal 0, previous["revenue"], "previous period revenue must be 0"
  end

  # --- Links Views ---

  test "links views returns correct link_views values from fixture data" do
    post "#{API_PREFIX}/projects/#{@project.id}/dashboard/links_views",
      params: { start_date: "2026-02-15", end_date: "2026-02-15" },
      headers: @headers
    assert_response :ok
    json = JSON.parse(response.body)
    metrics = json["metrics"]
    assert_kind_of Hash, metrics, "metrics must be a hash"

    # metric_day1 has link_views=80 on 2026-02-15
    assert_equal 80, metrics["2026-02-15"], "link_views on 2026-02-15 must be 80 from fixture"
  end

  # --- Best Performing Links ---

  test "top links returns fixture link with correct aggregated stats" do
    # link_daily_statistics has stat_day1 + stat_day2 for basic_link
    post "#{API_PREFIX}/projects/#{@project.id}/dashboard/top_links",
      params: { start_date: "2026-02-15", end_date: "2026-03-02" },
      headers: @headers
    assert_response :ok
    json = JSON.parse(response.body)
    assert_kind_of Array, json["links"], "links must be an array"
    assert json["links"].size >= 1, "must return at least the fixture link"

    # Find basic_link in results
    link_data = json["links"].find { |l| l["path"] == @link.path }
    assert_not_nil link_data, "fixture basic_link must appear in top links"

    # stat_day1 + stat_day2: views=100+200, opens=50+80, installs=10+20
    assert_equal 300, link_data["views"], "views must be sum of stat_day1 + stat_day2"
    assert_equal 130, link_data["opens"], "opens must be sum of stat_day1 + stat_day2"
    assert_equal 30, link_data["installs"], "installs must be sum of stat_day1 + stat_day2"
    assert_equal 7, link_data["reinstalls"], "reinstalls must be 2+5=7"
    assert_equal 4, link_data["reactivations"], "reactivations must be 1+3=4"
  end

  # --- Empty Date Range ---

  test "metrics overview with future date range returns all-zero metrics" do
    post "#{API_PREFIX}/projects/#{@project.id}/dashboard/metrics_overview",
      params: { start_date: "2099-01-01", end_date: "2099-12-31" },
      headers: @headers
    assert_response :ok
    json = JSON.parse(response.body)
    current = json["metrics"]["current"]
    assert_equal 0, current["views"], "future range views must be 0"
    assert_equal 0, current["installs"], "future range installs must be 0"
    assert_equal 0, current["revenue"], "future range revenue must be 0"
    assert_equal 0, current["opens"], "future range opens must be 0"
  end

  test "top links with future date range returns empty array" do
    post "#{API_PREFIX}/projects/#{@project.id}/dashboard/top_links",
      params: { start_date: "2099-01-01", end_date: "2099-12-31" },
      headers: @headers
    assert_response :ok
    json = JSON.parse(response.body)
    assert_kind_of Array, json["links"], "links must be an array"
    assert_equal 0, json["links"].size, "future range must have no top links"
  end

  # --- Cross-Tenant ---

  test "access another instance project dashboard returns 403 with no data leak" do
    post "#{API_PREFIX}/projects/#{@project_two.id}/dashboard/metrics_overview",
      headers: @headers
    assert_response :forbidden
    json = JSON.parse(response.body)
    assert_equal "Forbidden", json["error"]
    assert_not json.key?("metrics"), "403 must not leak metrics data"
    assert_not json.key?("links"), "403 must not leak link data"
  end
end
