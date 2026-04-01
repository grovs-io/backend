require "test_helper"
require_relative "auth_test_helper"

class SdkVisitorsTest < ActionDispatch::IntegrationTest
  include AuthTestHelper

  fixtures :instances, :projects, :applications, :ios_configurations,
           :android_configurations, :devices, :visitors, :domains, :redirect_configs

  setup do
    @project = projects(:one)
    @visitor = visitors(:ios_visitor)
    @device = devices(:ios_device)
    @headers = sdk_headers_for(@project, @visitor, platform: "ios")
  end

  # --- Unauthenticated ---

  test "get visitor attributes without SDK headers returns 403 with no data" do
    get "#{SDK_PREFIX}/visitor_attributes", headers: { "Host" => sdk_host }
    assert_response :forbidden
    json = JSON.parse(response.body)
    assert_not json.key?("visitor"), "403 must not leak visitor data"
  end

  # --- Get Attributes ---

  test "get visitor attributes returns correct visitor data" do
    get "#{SDK_PREFIX}/visitor_attributes", headers: @headers
    assert_response :ok
    json = JSON.parse(response.body)
    visitor_data = json["visitor"]
    assert visitor_data["uuid"].present?, "must return visitor UUID"
    assert visitor_data.key?("sdk_identifier"), "must include sdk_identifier"
    assert visitor_data.key?("sdk_attributes"), "must include sdk_attributes"
    assert visitor_data.key?("created_at"), "must include created_at"
  end

  # --- Set Attributes ---

  test "set visitor attributes persists sdk_identifier and sdk_attributes in DB" do
    post "#{SDK_PREFIX}/visitor_attributes",
      params: { sdk_identifier: "user-123", sdk_attributes: { plan: "premium", tier: 2 } },
      headers: @headers
    assert_response :ok
    json = JSON.parse(response.body)
    assert_equal "user-123", json["visitor"]["sdk_identifier"]

    @visitor.reload
    assert_equal "user-123", @visitor.sdk_identifier, "sdk_identifier must persist in DB"
    assert_equal "premium", @visitor.sdk_attributes["plan"], "sdk_attributes plan must persist"
    assert_equal "2", @visitor.sdk_attributes["tier"].to_s, "sdk_attributes tier must persist"
  end

  # --- Set Push Token ---

  test "set push token persists on device in DB" do
    post "#{SDK_PREFIX}/visitor_attributes",
      params: { push_token: "test-push-token-abc" },
      headers: @headers
    assert_response :ok

    @device.reload
    assert_equal "test-push-token-abc", @device.push_token, "push_token must persist on device in DB"
  end
end
