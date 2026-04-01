require "test_helper"
require_relative "auth_test_helper"

class ConfigurationsApiTest < ActionDispatch::IntegrationTest
  include AuthTestHelper

  fixtures :instances, :users, :instance_roles, :projects, :domains,
           :redirect_configs, :applications, :ios_configurations,
           :android_configurations, :desktop_configurations, :web_configurations

  setup do
    @admin_user = users(:admin_user)
    @member_user = users(:member_user)
    @instance = instances(:one)
    @instance_two = instances(:two)
    @ios_app = applications(:ios_app)
    @android_app = applications(:android_app)
    @headers = doorkeeper_headers_for(@admin_user)
  end

  # --- Unauthenticated ---

  test "get configurations without auth returns 401 with no data" do
    get "#{API_PREFIX}/instances/#{@instance.id}/configurations", headers: api_headers
    assert_response :unauthorized
    assert_no_match(/"configurations"/, response.body, "401 must not leak config data")
  end

  # --- List Configurations ---

  test "list configurations returns all platform apps with correct structure" do
    get "#{API_PREFIX}/instances/#{@instance.id}/configurations", headers: @headers
    assert_response :ok
    json = JSON.parse(response.body)
    assert_kind_of Array, json["configurations"]
    platforms = json["configurations"].map { |c| c["platform"] }
    assert_includes platforms, "ios"
    assert_includes platforms, "android"

    ios_config = json["configurations"].find { |c| c["platform"] == "ios" }
    assert ios_config["enabled"], "iOS app must be enabled"
    assert ios_config.key?("configuration"), "must include nested configuration"
  end

  # --- Set iOS Configuration ---

  test "set iOS configuration persists bundle_id in DB" do
    put "#{API_PREFIX}/instances/#{@instance.id}/configurations/ios",
      params: { enabled: true, bundle_id: "com.updated.bundle", app_prefix: "XYZ789" },
      headers: @headers
    assert_response :ok
    json = JSON.parse(response.body)
    assert_equal "ios", json["config"]["platform"]

    ios_config = IosConfiguration.find_by(application_id: @ios_app.id)
    assert_equal "com.updated.bundle", ios_config.bundle_id, "bundle_id must persist in DB"
    assert_equal "XYZ789", ios_config.app_prefix, "app_prefix must persist in DB"
  end

  # --- Set Android Configuration ---

  test "set Android configuration persists identifier in DB" do
    put "#{API_PREFIX}/instances/#{@instance.id}/configurations/android",
      params: { enabled: true, identifier: "com.updated.android" },
      headers: @headers
    assert_response :ok
    json = JSON.parse(response.body)
    assert_equal "android", json["config"]["platform"]

    android_config = AndroidConfiguration.find_by(application_id: @android_app.id)
    assert_equal "com.updated.android", android_config.identifier, "identifier must persist in DB"
  end

  # --- Set Desktop Configuration ---

  test "set Desktop configuration persists fallback_url in DB" do
    desktop_app = applications(:desktop_app)
    put "#{API_PREFIX}/instances/#{@instance.id}/configurations/desktop",
      params: { enabled: true, fallback_url: "https://updated.example.com", mac_enabled: true },
      headers: @headers
    assert_response :ok
    json = JSON.parse(response.body)
    assert_equal "desktop", json["config"]["platform"]

    desktop_config = DesktopConfiguration.find_by(application_id: desktop_app.id)
    assert_equal "https://updated.example.com", desktop_config.fallback_url, "fallback_url must persist"
    assert desktop_config.mac_enabled, "mac_enabled must persist"
  end

  # --- Set Web Configuration ---

  test "set Web configuration persists enabled state in DB" do
    web_app = applications(:web_app)
    put "#{API_PREFIX}/instances/#{@instance.id}/configurations/web",
      params: { enabled: true, domains: ["example.com"] },
      headers: @headers
    assert_response :ok
    json = JSON.parse(response.body)
    assert_equal "web", json["config"]["platform"]
    assert json["config"]["enabled"], "web app must be enabled in response"

    web_config = WebConfiguration.find_by(application_id: web_app.id)
    assert_not_nil web_config, "web configuration must exist in DB"
    web_app.reload
    assert web_app.enabled, "web app must be enabled in DB"
  end

  # --- Validation Errors ---

  test "set android API access key without android config returns 422" do
    # Destroy existing android configuration to trigger the precondition error
    @android_app.android_configuration&.destroy

    put "#{API_PREFIX}/instances/#{@instance.id}/configurations/android/api_access_key",
      params: { file: nil },
      headers: @headers
    assert_response :unprocessable_entity
    json = JSON.parse(response.body)
    assert_includes json["error"], "Android configuration must be set up first"
  end

  # --- Cross-Tenant ---

  test "access another instance configurations returns 403 with no data leak" do
    get "#{API_PREFIX}/instances/#{@instance_two.id}/configurations", headers: @headers
    assert_response :forbidden
    json = JSON.parse(response.body)
    assert_not json.key?("configurations"), "403 must not leak config data"
    assert_not json.key?("config"), "403 must not leak config data"
  end

  # --- Google Config Script ---

  test "google configuration script returns valid shell script" do
    get "#{API_PREFIX}/instances/#{@instance.id}/configurations/android/google_configuration_script",
      headers: @headers
    assert_response :ok
    assert_match %r{application/x-sh}, response.content_type
    assert_match(/\A#!/, response.body, "script must start with shebang")
    assert_match(/gcloud/, response.body, "script must contain gcloud commands")
  end
end
