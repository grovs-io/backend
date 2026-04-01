require "test_helper"
require_relative "auth_test_helper"

class SdkAuthTest < ActionDispatch::IntegrationTest
  include AuthTestHelper

  fixtures :instances, :projects, :applications, :ios_configurations,
           :android_configurations, :devices, :visitors, :domains, :redirect_configs

  setup do
    @project = projects(:one)
    @visitor = visitors(:ios_visitor)
  end

  # --- Missing All SDK Headers ---

  test "missing all SDK headers returns 403 with no data" do
    post "#{SDK_PREFIX}/event",
      params: { event: "app_open" },
      headers: { "Host" => sdk_host }
    assert_response :forbidden
    json = JSON.parse(response.body)
    assert_equal "Missing credentials", json["error"]
    assert_not json.key?("message"), "error response must not contain success message"
  end

  # --- Missing PLATFORM Header ---

  test "valid PROJECT-KEY but missing PLATFORM returns 403" do
    post "#{SDK_PREFIX}/event",
      params: { event: "app_open" },
      headers: { "PROJECT-KEY" => @project.identifier, "IDENTIFIER" => "com.test.iosapp",
                 "LINKSQUARED" => @visitor.hashid, "Host" => sdk_host }
    assert_response :forbidden
    json = JSON.parse(response.body)
    assert_equal "Missing credentials", json["error"]
  end

  # --- Nonexistent Project ---

  test "valid headers but nonexistent project returns 403" do
    post "#{SDK_PREFIX}/event",
      params: { event: "app_open" },
      headers: { "PROJECT-KEY" => "nonexistent-proj", "PLATFORM" => "ios",
                 "IDENTIFIER" => "com.test.iosapp", "LINKSQUARED" => @visitor.hashid,
                 "Host" => sdk_host }
    assert_response :forbidden
    json = JSON.parse(response.body)
    assert_equal "Invalid credentials", json["error"]
  end

  # --- iOS Identifier Mismatch ---

  test "iOS identifier mismatch returns 422 with descriptive error" do
    post "#{SDK_PREFIX}/event",
      params: { event: "app_open" },
      headers: { "PROJECT-KEY" => @project.identifier, "PLATFORM" => "ios",
                 "IDENTIFIER" => "com.wrong.bundleid", "LINKSQUARED" => @visitor.hashid,
                 "Host" => sdk_host }
    assert_response :unprocessable_entity
    json = JSON.parse(response.body)
    assert_match(/iOS.*not configured/i, json["error"])
  end

  # --- Android Identifier Mismatch ---

  test "Android identifier mismatch returns 422 with descriptive error" do
    post "#{SDK_PREFIX}/event",
      params: { event: "app_open" },
      headers: { "PROJECT-KEY" => @project.identifier, "PLATFORM" => "android",
                 "IDENTIFIER" => "com.wrong.package", "LINKSQUARED" => @visitor.hashid,
                 "Host" => sdk_host }
    assert_response :unprocessable_entity
    json = JSON.parse(response.body)
    assert_match(/Android.*not configured/i, json["error"])
  end

  # --- Missing LINKSQUARED Header ---

  test "valid project headers but missing LINKSQUARED returns 403" do
    post "#{SDK_PREFIX}/event",
      params: { event: "app_open" },
      headers: sdk_auth_headers_for(@project, platform: "ios")
    assert_response :forbidden
    json = JSON.parse(response.body)
    assert_equal "Invalid linksquared id", json["error"]
  end

  # --- Invalid LINKSQUARED Hashid ---

  test "invalid LINKSQUARED hashid returns 403" do
    headers = sdk_auth_headers_for(@project, platform: "ios")
    headers["LINKSQUARED"] = "bogus_invalid_hashid"
    post "#{SDK_PREFIX}/event",
      params: { event: "app_open" },
      headers: headers
    assert_response :forbidden
    json = JSON.parse(response.body)
    assert_equal "Invalid linksquared id", json["error"]
  end

  # --- Fully Valid SDK Auth ---

  test "fully valid SDK auth queues event to Redis" do
    redis_key = "events:pending"
    before_count = REDIS.with { |c| c.llen(redis_key) }

    headers = sdk_headers_for(@project, @visitor, platform: "ios")
    post "#{SDK_PREFIX}/event",
      params: { event: "app_open" },
      headers: headers
    assert_response :ok
    json = JSON.parse(response.body)
    assert_equal "Event added", json["message"]

    after_count = REDIS.with { |c| c.llen(redis_key) }
    assert_equal before_count + 1, after_count, "event must be pushed to Redis pending queue"
  end

  # --- Authenticate Endpoint (No Device Auth) ---

  test "SDK authenticate creates visitor and device, returns hashid" do
    headers = sdk_auth_headers_for(@project, platform: "ios")
    assert_difference "Visitor.count" do
      post "#{SDK_PREFIX}/authenticate",
        params: { vendor_id: "new-vendor-#{SecureRandom.hex(4)}", user_agent: "TestApp/2.0", app_version: "2.0" },
        headers: headers
    end
    assert_response :ok
    json = JSON.parse(response.body)
    assert json["linksquared"].present?, "must return linksquared hashid"
    assert_equal @project.instance.uri_scheme, json["uri_scheme"]

    # Verify the returned hashid resolves to a real visitor
    visitor = Visitor.find_by_hashid(json["linksquared"])
    assert_not_nil visitor, "returned hashid must resolve to an actual visitor"
    assert_equal @project.id, visitor.project_id
  end
end
