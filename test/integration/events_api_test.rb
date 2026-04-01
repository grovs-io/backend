require "test_helper"
require_relative "auth_test_helper"

class EventsApiTest < ActionDispatch::IntegrationTest
  include AuthTestHelper

  fixtures :instances, :users, :instance_roles, :projects, :domains,
           :redirect_configs, :links, :devices, :events

  setup do
    @admin_user = users(:admin_user)
    @project = projects(:one)
    @project_two = projects(:two)
    @instance = instances(:one)
    @link = links(:basic_link)
    @headers = doorkeeper_headers_for(@admin_user)

    # Attach fixture events to basic_link so event search/sorted tests return real metrics.
    # Done in setup (not fixture) to avoid polluting other test classes that share events.
    Event.where(id: [events(:view_event).id, events(:open_event).id,
                     events(:install_event).id, events(:android_view_event).id])
         .update_all(link_id: @link.id)
  end

  # --- Unauthenticated ---

  test "events for search params without auth returns 401 with no data" do
    post "#{API_PREFIX}/projects/#{@project.id}/events/search",
      params: { active: "true", sdk: "false", page: 1 },
      headers: api_headers
    assert_response :unauthorized
    assert_no_match(/"metrics"/, response.body, "401 must not leak event metrics")
  end

  # --- Events for Search Params ---

  test "events for search params returns metrics keyed by link_id with correct counts" do
    post "#{API_PREFIX}/projects/#{@project.id}/events/search",
      params: { active: "true", sdk: "false", page: 1,
                start_date: "2026-03-01", end_date: "2026-03-02" },
      headers: @headers
    assert_response :ok
    json = JSON.parse(response.body)
    metrics = json["metrics"]
    assert_kind_of Hash, metrics, "metrics must be a hash"

    # basic_link has 4 events with link_id set: 2 views, 1 open, 1 install
    link_id = @link.id.to_s
    assert metrics.key?(link_id), "metrics must include basic_link's ID #{link_id}"

    link_metrics = metrics[link_id]
    assert_equal 2, link_metrics["view"], "basic_link must have 2 view events"
    assert_equal 1, link_metrics["open"], "basic_link must have 1 open event"
    assert_equal 1, link_metrics["install"], "basic_link must have 1 install event"
  end

  # --- Events Sorted ---

  test "events sorted by view returns basic_link with correct view count" do
    post "#{API_PREFIX}/projects/#{@project.id}/events/sorted",
      params: { active: "true", sdk: "false", page: 1, event_type: "view",
                start_date: "2026-03-01", end_date: "2026-03-02" },
      headers: @headers
    assert_response :ok
    json = JSON.parse(response.body)
    assert_kind_of Array, json["result"], "sorted events must return result array"
    assert json.key?("page"), "sorted events must return page"
    assert json.key?("total_pages"), "sorted events must return total_pages"

    # basic_link should appear with 2 views (view_event + android_view_event)
    if json["result"].any?
      entry = json["result"].first
      assert entry.key?("link"), "each result must include link"
      assert entry.key?("metrics"), "each result must include metrics"
      assert_equal 2, entry["metrics"]["view"], "basic_link must have 2 views"
    end
  end

  # --- Events Overview ---

  test "events overview returns correct event counts per date from fixtures" do
    post "#{API_PREFIX}/projects/#{@project.id}/events/overview",
      params: { start_date: "2026-03-01", end_date: "2026-03-02" },
      headers: @headers
    assert_response :ok
    json = JSON.parse(response.body)
    assert_kind_of Hash, json, "overview must return a hash"

    # Find entries for our fixture dates (key format may include timestamp)
    day1_key = json.keys.find { |k| k.start_with?("2026-03-01") }
    day2_key = json.keys.find { |k| k.start_with?("2026-03-02") }
    assert_not_nil day1_key, "must have entry for 2026-03-01"
    assert_not_nil day2_key, "must have entry for 2026-03-02"

    # 2026-03-01: view_event, open_event, install_event (all ios)
    assert_equal 1, json[day1_key]["view"], "2026-03-01 must have 1 view event"
    assert_equal 1, json[day1_key]["open"], "2026-03-01 must have 1 open event"
    assert_equal 1, json[day1_key]["install"], "2026-03-01 must have 1 install event"

    # 2026-03-02: android_view_event, web_app_open_event, reinstall_event
    assert_equal 1, json[day2_key]["view"], "2026-03-02 must have 1 view event"
    assert_equal 1, json[day2_key]["app_open"], "2026-03-02 must have 1 app_open event"
    assert_equal 1, json[day2_key]["reinstall"], "2026-03-02 must have 1 reinstall event"
  end

  # --- Metrics Values ---

  test "metrics values returns platforms matching fixture events" do
    get "#{API_PREFIX}/projects/#{@project.id}/events/metric_values",
      headers: @headers
    assert_response :ok
    json = JSON.parse(response.body)
    values = json["metrics_values"]
    assert_kind_of Hash, values, "metrics_values must be a hash"

    # Fixture events have platforms: ios, android, web
    %w[ios android web].each do |platform|
      assert_includes values["platforms"], platform,
        "platforms must include #{platform} from fixture events"
    end

    assert_kind_of Array, values["app_versions"], "app_versions must be an array"
    assert_kind_of Array, values["builds"], "builds must be an array"
  end

  # --- Events for Billing ---

  test "events for billing returns metrics data" do
    post "#{API_PREFIX}/instances/#{@instance.id}/events/billing",
      params: { start_date: 30.days.ago.to_date.to_s, end_date: Date.today.to_s },
      headers: @headers
    # Instance has both test + production projects → 200 with metrics
    # If not configured → 404 with error
    if response.status == 200
      json = JSON.parse(response.body)
      assert json.key?("metrics_values"), "billing must return metrics_values"
      assert_kind_of Hash, json["metrics_values"], "metrics_values must be a hash"
    else
      assert_response :not_found
      json = JSON.parse(response.body)
      assert_equal "Instance projects not configured", json["error"]
    end
  end

  # --- Empty Date Range ---

  test "events overview with past date range having no events returns zero counts" do
    post "#{API_PREFIX}/projects/#{@project.id}/events/overview",
      params: { start_date: "2020-01-01", end_date: "2020-01-02" },
      headers: @headers
    assert_response :ok
    json = JSON.parse(response.body)
    assert_kind_of Hash, json, "overview must return a hash"
    # All values should be zero or dates with zero counts
    json.each_value do |day_data|
      next unless day_data.is_a?(Hash)
      day_data.each_value do |count|
        assert_equal 0, count, "all event counts must be 0 for past date range"
      end
    end
  end

  # --- Sorted with No Matching Events ---

  test "events sorted by reinstall on date with no reinstalls returns empty result" do
    post "#{API_PREFIX}/projects/#{@project.id}/events/sorted",
      params: { active: "true", sdk: "false", page: 1, event_type: "reinstall",
                start_date: "2020-01-01", end_date: "2020-01-02" },
      headers: @headers
    assert_response :ok
    json = JSON.parse(response.body)
    assert_kind_of Array, json["result"], "sorted events must return result array"
    assert_equal 0, json["result"].size, "no reinstalls in 2020 date range"
  end

  # --- Metric Values on Empty Project ---

  test "metric values on project with no events returns empty arrays" do
    empty_project = projects(:one_test)
    get "#{API_PREFIX}/projects/#{empty_project.id}/events/metric_values",
      headers: @headers
    assert_response :ok
    json = JSON.parse(response.body)
    values = json["metrics_values"]
    assert_equal [], values["platforms"], "platforms must be empty on project with no events"
    assert_equal [], values["app_versions"], "app_versions must be empty on project with no events"
    assert_equal [], values["builds"], "builds must be empty on project with no events"
  end

  # --- Missing Required Param ---

  test "events sorted without event_type param returns 400" do
    post "#{API_PREFIX}/projects/#{@project.id}/events/sorted",
      params: { active: "true", sdk: "false", page: 1,
                start_date: "2026-03-01", end_date: "2026-03-02" },
      headers: @headers
    assert_response :bad_request
  end

  # --- Cross-Tenant ---

  test "access another instance project events returns 403 with no data leak" do
    post "#{API_PREFIX}/projects/#{@project_two.id}/events/search",
      params: { active: "true", sdk: "false", page: 1 },
      headers: @headers
    assert_response :forbidden
    json = JSON.parse(response.body)
    assert_equal "Forbidden", json["error"]
    assert_not json.key?("metrics"), "403 must not leak event metrics"
    assert_not json.key?("data"), "403 must not leak event data"
  end
end
