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

  test "visitor details returns zero-filled metrics for a visitor with no daily stats" do
    visitor = create_visitor

    get "#{API_PREFIX}/projects/#{@project.id}/visitors/#{visitor.id}", headers: @headers

    assert_response :ok
    json = JSON.parse(response.body)

    metrics = json["metrics"]
    assert_kind_of Hash, metrics, "metrics must be zero-filled, not null"
    assert_equal visitor.uuid, metrics["uuid"]
    assert_equal "ios", metrics["platform"]
    VisitorDailyStatistic::METRIC_COLUMNS.each do |col|
      assert_equal 0, metrics["total_#{col}"], "total_#{col} must be 0"
    end

    aggregated = json["aggregated_metrics"]
    assert_kind_of Hash, aggregated, "aggregated_metrics must be zero-filled, not null"
    assert_equal visitor.uuid, aggregated["uuid"]
    VisitorDailyStatistic::METRIC_COLUMNS.each do |col|
      assert_equal 0, aggregated["invited_#{col}"], "invited_#{col} must be 0"
    end
  end

  test "zero-filled metrics and aggregated_metrics shapes match the populated shapes" do
    empty_visitor = create_visitor
    populated_visitor = create_visitor
    VisitorDailyStatistic.create!(visitor: populated_visitor, project_id: @project.id,
                                  event_date: Date.current, platform: "ios", views: 1)
    VisitorDailyStatistic.create!(visitor: empty_visitor, invited_by_id: populated_visitor.id,
                                  project_id: @project.id, event_date: Date.current, platform: "ios", views: 1)

    get "#{API_PREFIX}/projects/#{@project.id}/visitors/#{populated_visitor.id}", headers: @headers
    populated = JSON.parse(response.body)
    assert_equal 1, populated["metrics"]["total_views"], "populated path must be exercised"
    assert_equal 1, populated["aggregated_metrics"]["invited_views"], "populated referral path must be exercised"

    # empty_visitor has an own-stats row but zero referral rows → metrics populated, aggregated zero-filled
    get "#{API_PREFIX}/projects/#{@project.id}/visitors/#{empty_visitor.id}", headers: @headers
    mixed = JSON.parse(response.body)

    zero_only = create_visitor
    get "#{API_PREFIX}/projects/#{@project.id}/visitors/#{zero_only.id}", headers: @headers
    zeroed = JSON.parse(response.body)

    assert_equal populated["metrics"].keys.sort, zeroed["metrics"].keys.sort,
                 "zero-filled and populated metrics must expose identical keys"
    assert_equal populated["aggregated_metrics"].keys.sort, zeroed["aggregated_metrics"].keys.sort,
                 "zero-filled and populated aggregated_metrics must expose identical keys"
    assert_equal populated["aggregated_metrics"].keys.sort, mixed["aggregated_metrics"].keys.sort
  end

  test "zero-filled metrics keep the platform key when device platform is null" do
    device = Device.create!(user_agent: "x", ip: "10.2.2.3", remote_ip: "10.2.2.3",
                            vendor: "zf-#{SecureRandom.hex(4)}")
    visitor = Visitor.create!(project: @project, device: device, uuid: SecureRandom.uuid)

    get "#{API_PREFIX}/projects/#{@project.id}/visitors/#{visitor.id}", headers: @headers

    metrics = JSON.parse(response.body)["metrics"]
    assert metrics.key?("platform"), "platform key must be present even when the value is null"
    assert_nil metrics["platform"]
  end

  # --- Nonexistent Visitor ---

  test "visitor details rejects a non-numeric id with 400 (uuid would integer-cast to a wrong visitor)" do
    get "#{API_PREFIX}/projects/#{@project.id}/visitors/550e8400-e29b-41d4-a716-446655440001",
      headers: @headers
    assert_response :bad_request
    assert_equal "visitor_id must be numeric", JSON.parse(response.body)["error"]
  end

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

  private

  def create_visitor
    device = Device.create!(user_agent: "x", ip: "10.2.2.1", remote_ip: "10.2.2.1",
                            platform: "ios", vendor: "zf-#{SecureRandom.hex(4)}")
    Visitor.create!(project: @project, device: device, uuid: SecureRandom.uuid)
  end
end

class VisitorsLegacyMetricsTest < ActionDispatch::IntegrationTest
  include AuthTestHelper

  fixtures :instances, :users, :instance_roles, :projects, :domains,
           :redirect_configs, :devices, :visitors, :links,
           :visitor_daily_statistics

  setup do
    @project = projects(:one)
    @visitor = visitors(:ios_visitor)
    @headers = doorkeeper_headers_for(users(:admin_user))
  end

  test "aggregated_metrics counts events on links the visitor created" do
    link = links(:basic_link)
    link.update_columns(visitor_id: @visitor.id)
    Event.where(link_id: link.id).delete_all
    2.times do 
      Event.create!(project_id: @project.id, device_id: @visitor.device_id,
                            link_id: link.id, event: Grovs::Events::OPEN)
    end
    Event.create!(project_id: @project.id, device_id: @visitor.device_id,
                  link_id: link.id, event: Grovs::Events::INSTALL)

    post "#{API_PREFIX}/projects/#{@project.id}/visitors/aggregated_metrics",
      params: { page: 1 }, headers: @headers

    assert_response :ok
    json = JSON.parse(response.body)
    row = json["metrics"].find { |r| r["id"] == @visitor.id }
    assert row, "creator visitor must appear"
    assert_equal 2, row["open_count"], "2 opens on the visitor's link"
    assert_equal 1, row["install_count"], "1 install on the visitor's link"
    assert_equal "1", json["page"].to_s
  end

  test "metrics counts the visitor's own device events" do
    Event.where(device_id: @visitor.device_id).delete_all
    3.times do 
      Event.create!(project_id: @project.id, device_id: @visitor.device_id,
                            event: Grovs::Events::APP_OPEN)
    end
    Event.create!(project_id: @project.id, device_id: @visitor.device_id,
                  event: Grovs::Events::INSTALL, engagement_time: 70)

    post "#{API_PREFIX}/projects/#{@project.id}/visitors/metrics",
      params: { page: 1, visitor_id: @visitor.id }, headers: @headers

    assert_response :ok
    json = JSON.parse(response.body)
    ids = json["metrics"].map { |v| v["id"] }.uniq
    assert_equal [@visitor.id], ids, "rows must belong to the requested visitor"
    row = json["metrics"][0]
    assert_equal 3, row["app_open_count"]
    assert_equal 1, row["install_count"]
    assert_equal 0, row["view_count"]
  end

  test "metrics with date range excluding all data returns empty rows" do
    post "#{API_PREFIX}/projects/#{@project.id}/visitors/metrics",
      params: { page: 1, start_date: "2030-01-01", end_date: "2030-01-02" },
      headers: @headers

    assert_response :ok
    assert_equal [], JSON.parse(response.body)["metrics"]
  end

  test "aggregated_metrics rejects other instances' projects" do
    post "#{API_PREFIX}/projects/#{projects(:two).id}/visitors/aggregated_metrics",
      params: { page: 1 }, headers: doorkeeper_headers_for(users(:member_user))

    assert_response :forbidden
  end
end
