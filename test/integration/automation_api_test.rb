require "test_helper"
require_relative "auth_test_helper"

class AutomationApiTest < ActionDispatch::IntegrationTest
  include AuthTestHelper

  fixtures :instances, :users, :instance_roles, :projects, :domains,
           :redirect_configs, :devices, :visitors, :links

  setup do
    @instance = instances(:one)
    @project = projects(:one)
    @visitor = visitors(:ios_visitor)
    @device = devices(:ios_device)
    @link = links(:basic_link)
    @admin_api_key = "test-admin-api-key"
    ENV["ADMIN_API_KEY"] = @admin_api_key
  end

  teardown do
    ENV.delete("ADMIN_API_KEY")
  end

  def automation_headers
    api_headers.merge("X-AUTH" => @admin_api_key, "Content-Type" => "application/json")
  end

  # --- Unauthenticated ---

  test "metrics_for_user without X-AUTH returns 403 with no data" do
    post "#{API_PREFIX}/automation/metrics_for_user",
      params: { key: @instance.api_key, vendor_id: @device.vendor, test: false }.to_json,
      headers: api_headers.merge("Content-Type" => "application/json")
    assert_response :forbidden
    json = JSON.parse(response.body)
    assert_equal "Invalid credentials", json["error"]
    assert_not json.key?("visitor"), "403 must not leak visitor data"
    assert_not json.key?("metrics"), "403 must not leak metrics data"
  end

  test "metrics_for_user with wrong X-AUTH returns 403 with no data" do
    post "#{API_PREFIX}/automation/metrics_for_user",
      params: { key: @instance.api_key, vendor_id: @device.vendor, test: false }.to_json,
      headers: api_headers.merge("X-AUTH" => "wrong-key", "Content-Type" => "application/json")
    assert_response :forbidden
    json = JSON.parse(response.body)
    assert_equal "Invalid credentials", json["error"]
  end

  # --- Metrics for User ---

  test "metrics_for_user with valid auth returns correct visitor and metrics" do
    post "#{API_PREFIX}/automation/metrics_for_user",
      params: { key: @instance.api_key, vendor_id: @device.vendor, test: false }.to_json,
      headers: automation_headers
    assert_response :ok
    json = JSON.parse(response.body)
    assert_equal @visitor.uuid, json["visitor"]["uuid"], "must return correct visitor UUID"
    assert json.key?("metrics"), "must return metrics key"
    assert json.key?("aggregated_metrics"), "must return aggregated_metrics key"
    # metrics/aggregated_metrics may be nil when visitor has no events — verify type when present
    assert_kind_of Hash, json["metrics"], "metrics must be a hash" if json["metrics"]
    assert_kind_of Hash, json["aggregated_metrics"], "aggregated_metrics must be a hash" if json["aggregated_metrics"]
    assert_kind_of Integer, json["number_of_generated_links"], "link count must be integer"
  end

  test "metrics_for_user with invalid api_key returns 404 with descriptive error" do
    post "#{API_PREFIX}/automation/metrics_for_user",
      params: { key: "invalid-key", vendor_id: @device.vendor, test: false }.to_json,
      headers: automation_headers
    assert_response :not_found
    json = JSON.parse(response.body)
    assert_equal "Key is invalid", json["error"]
    assert_not json.key?("visitor"), "error must not leak visitor data"
  end

  test "metrics_for_user with invalid vendor_id returns 404 with descriptive error" do
    post "#{API_PREFIX}/automation/metrics_for_user",
      params: { key: @instance.api_key, vendor_id: "nonexistent-vendor", test: false }.to_json,
      headers: automation_headers
    assert_response :not_found
    json = JSON.parse(response.body)
    assert_equal "Device is invalid", json["error"]
    assert_not json.key?("visitor"), "error must not leak visitor data"
  end

  # --- Details for Link ---

  test "details_for_link with valid auth returns link and metrics" do
    post "#{API_PREFIX}/automation/details_for_link",
      params: { key: @instance.api_key, path: @link.path, test: false }.to_json,
      headers: automation_headers
    assert_response :ok
    json = JSON.parse(response.body)
    assert_not_nil json["link"], "must return link data"
    assert_equal @link.path, json["link"]["path"], "must return correct link path"
    assert json.key?("metrics"), "must return metrics"
  end

  test "details_for_link with nonexistent path returns nil link and nil metrics" do
    post "#{API_PREFIX}/automation/details_for_link",
      params: { key: @instance.api_key, path: "nonexistent-path", test: false }.to_json,
      headers: automation_headers
    assert_response :ok
    json = JSON.parse(response.body)
    assert_nil json["link"], "nonexistent path must return nil link"
    assert_nil json["metrics"], "nonexistent path must return nil metrics"
  end
end
