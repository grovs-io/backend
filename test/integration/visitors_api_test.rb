require "test_helper"
require_relative "auth_test_helper"

class VisitorsApiTest < ActionDispatch::IntegrationTest
  include AuthTestHelper

  fixtures :instances, :users, :instance_roles, :projects, :domains,
           :redirect_configs, :devices, :visitors, :links,
           :visitor_daily_statistics

  setup do
    @admin_user = users(:admin_user)
    @project = projects(:one)
    @project_two = projects(:two)
    @visitor = visitors(:ios_visitor)
    @android_visitor = visitors(:android_visitor)
    @headers = doorkeeper_headers_for(@admin_user)
  end

  # --- Unauthenticated ---

  test "visitor details without auth returns 401 with no data" do
    get "#{API_PREFIX}/projects/#{@project.id}/visitors/#{@visitor.id}", headers: api_headers
    assert_response :unauthorized
    assert_no_match(/"visitor"/, response.body, "401 must not leak visitor data")
  end

  # --- Search Visitors ---

  test "search visitors returns fixture visitors with correct aggregated metrics" do
    post "#{API_PREFIX}/projects/#{@project.id}/visitors/search",
      params: { start_date: "2026-03-01", end_date: "2026-03-02" },
      headers: @headers
    assert_response :ok
    json = JSON.parse(response.body)
    visitors_data = json["visitors"]
    assert_kind_of Array, visitors_data, "must return visitors array"

    # Meta pagination
    meta = json["meta"]
    assert_equal 1, meta["page"], "first page"
    assert meta["total_entries"] >= 2, "must have at least ios_visitor + android_visitor"

    # Find ios_visitor by uuid
    ios_v = visitors_data.find { |v| v["uuid"] == @visitor.uuid }
    assert_not_nil ios_v, "ios_visitor must appear in search results"

    # ios_stat_day1 + ios_stat_day2: views=50+80=130, opens=20+30=50, installs=5+8=13
    assert_equal 130, ios_v["total_views"], "ios_visitor total_views must be 130"
    assert_equal 50, ios_v["total_opens"], "ios_visitor total_opens must be 50"
    assert_equal 13, ios_v["total_installs"], "ios_visitor total_installs must be 13"
    assert_equal 3, ios_v["total_reinstalls"], "ios_visitor total_reinstalls must be 1+2=3"
    assert_equal 8000, ios_v["total_time_spent"], "ios_visitor total_time_spent must be 3000+5000=8000"
    assert_equal 1300, ios_v["total_revenue"], "ios_visitor total_revenue must be 500+800=1300"

    # Find android_visitor
    android_v = visitors_data.find { |v| v["uuid"] == @android_visitor.uuid }
    assert_not_nil android_v, "android_visitor must appear in search results"
    assert_equal 30, android_v["total_views"], "android_visitor total_views must be 30"
    assert_equal 3, android_v["total_installs"], "android_visitor total_installs must be 3"
  end

  # --- Aggregated Visitors ---

  test "aggregated visitors returns visitors with pagination meta" do
    post "#{API_PREFIX}/projects/#{@project.id}/visitors/aggregated",
      params: { start_date: "2026-03-01", end_date: "2026-03-02" },
      headers: @headers
    assert_response :ok
    json = JSON.parse(response.body)
    assert_kind_of Array, json["visitors"], "must return visitors array"
    meta = json["meta"]
    %w[page total_pages per_page total_entries].each do |key|
      assert meta.key?(key), "meta must include #{key}"
    end
  end

  # --- Visitor Details ---

  test "visitor details returns correct visitor with metrics from fixture data" do
    get "#{API_PREFIX}/projects/#{@project.id}/visitors/#{@visitor.id}",
      headers: @headers
    assert_response :ok
    json = JSON.parse(response.body)
    visitor_data = json["visitor"]
    assert_equal @visitor.uuid, visitor_data["uuid"], "must return correct visitor UUID"
    assert visitor_data.key?("sdk_identifier"), "must include sdk_identifier"
    assert visitor_data.key?("sdk_attributes"), "must include sdk_attributes"

    # metrics may be nil if no stats exist in the queried date range (depends on visitor.created_at)
    # but we verify the key structure
    assert json.key?("metrics"), "must return metrics key"
    assert json.key?("aggregated_metrics"), "must return aggregated_metrics key"
    assert_kind_of Integer, json["number_of_generated_links"], "must return link count as integer"
  end

  # --- Nonexistent Visitor ---

  test "visitor details for nonexistent ID returns 404 with no data leak" do
    get "#{API_PREFIX}/projects/#{@project.id}/visitors/999999999",
      headers: @headers
    assert_response :not_found
    json = JSON.parse(response.body)
    assert json.key?("error"), "404 must include error message"
    assert_no_match(/"visitor"/, response.body, "404 must not leak visitor data")
  end

  # --- Empty Search Results ---

  test "search with nonexistent term returns empty visitors array" do
    post "#{API_PREFIX}/projects/#{@project.id}/visitors/search",
      params: { start_date: "2026-03-01", end_date: "2026-03-02", term: "nonexistent-uuid-xyz-999" },
      headers: @headers
    assert_response :ok
    json = JSON.parse(response.body)
    assert_kind_of Array, json["visitors"], "must return visitors array"
    assert_equal 0, json["visitors"].size, "no visitor matches nonexistent term"
    meta = json["meta"]
    assert_not_nil meta, "must include pagination meta"
    assert_equal 1, meta["page"], "page must default to 1"
  end

  # --- Pagination Beyond Range ---

  test "search with page beyond range returns empty visitors array with valid meta" do
    post "#{API_PREFIX}/projects/#{@project.id}/visitors/search",
      params: { start_date: "2026-03-01", end_date: "2026-03-02", page: 999 },
      headers: @headers
    assert_response :ok
    json = JSON.parse(response.body)
    assert_kind_of Array, json["visitors"], "must return visitors array"
    assert_equal 0, json["visitors"].size, "page 999 has no visitors"
    meta = json["meta"]
    assert_equal 999, meta["page"], "must reflect requested page"
    assert meta["total_entries"] >= 0, "total_entries must be valid"
  end

  # --- No Statistics in Date Range ---

  test "visitor details with date range having no stats returns 200 without error" do
    get "#{API_PREFIX}/projects/#{@project.id}/visitors/#{@visitor.id}",
      params: { start_date: "2020-01-01", end_date: "2020-01-02" },
      headers: @headers
    assert_response :ok
    json = JSON.parse(response.body)
    assert_equal @visitor.uuid, json["visitor"]["uuid"], "must return correct visitor"
    # metrics may be nil or empty when no stats exist — but must not 500
    assert json.key?("metrics"), "must include metrics key even if empty"
  end

  # --- Cross-Tenant ---

  test "access another instance project visitors returns 403 with no data leak" do
    post "#{API_PREFIX}/projects/#{@project_two.id}/visitors/search",
      params: { start_date: 30.days.ago.to_date.to_s, end_date: Date.today.to_s },
      headers: @headers
    assert_response :forbidden
    json = JSON.parse(response.body)
    assert_equal "Forbidden", json["error"]
    assert_not json.key?("visitors"), "403 must not leak visitor data"
    assert_not json.key?("visitor"), "403 must not leak visitor data"
  end
end
