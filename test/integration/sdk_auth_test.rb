require "test_helper"
require_relative "auth_test_helper"
require "sidekiq/testing"

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

  # --- Cross-tenant visitor scoping ---

  test "LINKSQUARED id belonging to another project is rejected" do
    other_project = projects(:two)
    other_device = Device.create!(vendor: "victim-vendor-#{SecureRandom.hex(4)}",
                                  platform: "ios", user_agent: "TestApp/1.0 iPhone",
                                  ip: "192.168.9.9", remote_ip: "10.0.9.9")
    other_visitor = Visitor.create!(project: other_project, device: other_device)

    headers = sdk_auth_headers_for(@project, platform: "ios")
    headers["LINKSQUARED"] = other_visitor.hashid

    post "#{SDK_PREFIX}/event",
      params: { event: "app_open" },
      headers: headers

    assert_response :forbidden
    json = JSON.parse(response.body)
    assert_equal "Invalid linksquared id", json["error"]
  end

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

  # The mobile SDKs send the model under `device`; older/server callers use `model`.
  test "SDK authenticate stores the model sent as device" do
    headers = sdk_auth_headers_for(@project, platform: "ios")
    vendor = "model-vendor-#{SecureRandom.hex(4)}"

    post "#{SDK_PREFIX}/authenticate",
      params: { vendor_id: vendor, user_agent: "TestApp/2.0", app_version: "2.0",
                device: "iPhone 15 Pro" },
      headers: headers

    assert_response :ok
    assert_equal "iPhone 15 Pro", Device.find_by(vendor: vendor).model
  end

  test "SDK authenticate stores the model sent as model" do
    headers = sdk_auth_headers_for(@project, platform: "ios")
    vendor = "model-vendor-#{SecureRandom.hex(4)}"

    post "#{SDK_PREFIX}/authenticate",
      params: { vendor_id: vendor, user_agent: "TestApp/2.0", app_version: "2.0",
                model: "Pixel 8" },
      headers: headers

    assert_response :ok
    assert_equal "Pixel 8", Device.find_by(vendor: vendor).model
  end

  test "SDK authenticate maps a raw Apple identifier to its marketing name" do
    headers = sdk_auth_headers_for(@project, platform: "ios")
    vendor = "model-vendor-#{SecureRandom.hex(4)}"

    post "#{SDK_PREFIX}/authenticate",
      params: { vendor_id: vendor, user_agent: "TestApp/2.0", app_version: "2.0",
                device: "iPhone17,3" },
      headers: headers

    assert_response :ok
    assert_equal "iPhone 16", Device.find_by(vendor: vendor).model
  end

  test "SDK authenticate passes an unknown Apple identifier through untouched" do
    headers = sdk_auth_headers_for(@project, platform: "ios")
    vendor = "model-vendor-#{SecureRandom.hex(4)}"

    post "#{SDK_PREFIX}/authenticate",
      params: { vendor_id: vendor, user_agent: "TestApp/2.0", app_version: "2.0",
                device: "iPhone99,9" },
      headers: headers

    assert_response :ok
    assert_equal "iPhone99,9", Device.find_by(vendor: vendor).model
  end

  test "SDK authenticate maps an Android model through the CSV table" do
    REDIS.with { |conn| conn.hset(AndroidDeviceModels::KEY, "SM-S928B" => "Samsung Galaxy S24 Ultra") }
    headers = sdk_auth_headers_for(@project, platform: "android")
    vendor = "model-vendor-#{SecureRandom.hex(4)}"

    post "#{SDK_PREFIX}/authenticate",
      params: { vendor_id: vendor, user_agent: "TestApp/2.0", app_version: "2.0",
                device: "SM-S928B" },
      headers: headers

    assert_response :ok
    assert_equal "Samsung Galaxy S24 Ultra", Device.find_by(vendor: vendor).model
  ensure
    REDIS.del(AndroidDeviceModels::KEY, AndroidDeviceModels::REFRESH_LOCK)
  end

  test "SDK authenticate passes an unmapped Android model through untouched" do
    REDIS.with { |conn| conn.hset(AndroidDeviceModels::KEY, "SM-S928B" => "Samsung Galaxy S24 Ultra") }
    headers = sdk_auth_headers_for(@project, platform: "android")
    vendor = "model-vendor-#{SecureRandom.hex(4)}"

    post "#{SDK_PREFIX}/authenticate",
      params: { vendor_id: vendor, user_agent: "TestApp/2.0", app_version: "2.0",
                device: "Google Pixel 8" },
      headers: headers

    assert_response :ok
    assert_equal "Google Pixel 8", Device.find_by(vendor: vendor).model
  ensure
    REDIS.del(AndroidDeviceModels::KEY, AndroidDeviceModels::REFRESH_LOCK)
  end

  test "SDK authenticate backfills the model on an already known device" do
    device = @visitor.device
    device.update_columns(model: nil)
    device.send(:clear_cache)
    # 300s-TTL update dedup keys are keyed by DB id, which fixtures reuse every run
    dedup_keys = ["dev_upd_basic:#{device.id}", "dev_upd_full:#{device.id}"]
    REDIS.del(*dedup_keys)

    Sidekiq::Testing.inline! do
      post "#{SDK_PREFIX}/authenticate",
        params: { vendor_id: device.vendor, user_agent: device.user_agent, app_version: "2.0",
                  device: "iPhone 15 Pro" },
        headers: sdk_auth_headers_for(@project, platform: "ios")
    end

    assert_response :ok
    assert_equal "iPhone 15 Pro", device.reload.model
  ensure
    REDIS.del(*dedup_keys) if dedup_keys
  end
end

class SdkDeviceForVendorTest < ActionDispatch::IntegrationTest
  include AuthTestHelper

  fixtures :instances, :projects, :applications, :ios_configurations,
           :android_configurations, :devices, :visitors, :domains, :redirect_configs

  setup do
    @project = projects(:one)
    @visitor = visitors(:ios_visitor)
    @device = @visitor.device
    @headers = sdk_headers_for(@project, @visitor, platform: "ios")
  end

  test "unknown vendor returns null last_seen" do
    get "#{SDK_PREFIX}/device_for_vendor_id",
      params: { vendor_id: "vendor-that-does-not-exist" }, headers: @headers

    assert_response :ok
    assert_nil JSON.parse(response.body)["last_seen"]
  end

  test "known vendor with no events returns null last_seen" do
    Event.where(device_id: @device.id, project_id: @project.id).delete_all

    get "#{SDK_PREFIX}/device_for_vendor_id",
      params: { vendor_id: @device.vendor }, headers: @headers

    assert_response :ok
    assert_nil JSON.parse(response.body)["last_seen"]
  end

  test "known vendor returns the most recent event time for this project" do
    Event.where(device_id: @device.id, project_id: @project.id).delete_all
    Event.create!(project_id: @project.id, device_id: @device.id,
                  event: Grovs::Events::APP_OPEN, created_at: 3.days.ago)
    newest = Event.create!(project_id: @project.id, device_id: @device.id,
                           event: Grovs::Events::APP_OPEN, created_at: 1.hour.ago)

    get "#{SDK_PREFIX}/device_for_vendor_id",
      params: { vendor_id: @device.vendor }, headers: @headers

    assert_response :ok
    last_seen = Time.zone.parse(JSON.parse(response.body)["last_seen"])
    assert_in_delta newest.created_at.to_f, last_seen.to_f, 1.0
  end

  test "events from another project do not leak into last_seen" do
    Event.where(device_id: @device.id).delete_all
    Event.create!(project_id: projects(:two).id, device_id: @device.id,
                  event: Grovs::Events::APP_OPEN, created_at: 1.minute.ago)

    get "#{SDK_PREFIX}/device_for_vendor_id",
      params: { vendor_id: @device.vendor }, headers: @headers

    assert_response :ok
    assert_nil JSON.parse(response.body)["last_seen"],
      "another project's events must not count as last_seen"
  end
end
