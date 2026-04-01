require "test_helper"
require_relative "auth_test_helper"

class RedirectsApiTest < ActionDispatch::IntegrationTest
  include AuthTestHelper

  fixtures :instances, :users, :instance_roles, :projects, :domains,
           :redirect_configs

  setup do
    @admin_user = users(:admin_user)
    @project = projects(:one)
    @project_two = projects(:two)
    @headers = doorkeeper_headers_for(@admin_user)
  end

  # --- Unauthenticated ---

  test "get redirect config without auth returns 401 with no data" do
    get "#{API_PREFIX}/projects/#{@project.id}/redirect_config", headers: api_headers
    assert_response :unauthorized
    assert_no_match(/"redirect_config"/, response.body, "401 must not leak redirect data")
  end

  # --- Get Redirect Config ---

  test "get redirect config returns config with platform sections and correct values" do
    get "#{API_PREFIX}/projects/#{@project.id}/redirect_config", headers: @headers
    assert_response :ok
    json = JSON.parse(response.body)
    config = json["redirect_config"]

    # Verify values match DB, not just key existence
    db_config = @project.redirect_config
    if db_config.default_fallback.nil?
      assert_nil config["default_fallback"], "default_fallback must be nil when DB is nil"
    else
      assert_equal db_config.default_fallback, config["default_fallback"], "default_fallback must match DB"
    end
    # Boolean fields — use explicit nil check to avoid assert_equal(nil, nil) deprecation
    [["show_preview_ios", db_config.show_preview_ios],
     ["show_preview_android", db_config.show_preview_android]].each do |key, db_value|
      if db_value.nil?
        assert_nil config[key], "#{key} must be nil when DB is nil"
      else
        assert_equal db_value, config[key], "#{key} must match DB"
      end
    end

    # Verify platform sections exist as hashes
    assert_kind_of Hash, config["ios"], "ios section must be a hash"
    assert_kind_of Hash, config["android"], "android section must be a hash"
    assert_kind_of Hash, config["desktop"], "desktop section must be a hash"
  end

  # --- Set Redirect Config ---

  test "set redirect config persists default_fallback in DB" do
    put "#{API_PREFIX}/projects/#{@project.id}/redirect_config",
      params: { default_fallback: "https://fallback.example.com", show_preview_ios: true },
      headers: @headers
    assert_response :ok

    @project.redirect_config.reload
    assert_equal "https://fallback.example.com", @project.redirect_config.default_fallback, "fallback must persist"
    assert @project.redirect_config.show_preview_ios, "show_preview_ios must persist"
  end

  # --- Set Platform Redirect ---

  test "set redirect for iOS phone with fallback URL persists in DB" do
    put "#{API_PREFIX}/projects/#{@project.id}/redirect_config/redirect",
      params: { platform: "ios", variation: "phone", fallback_url: "https://ios.example.com", appstore: false, enabled: true },
      headers: @headers
    assert_response :ok
    json = JSON.parse(response.body)
    assert json.key?("config"), "must return config key"

    redirect = Redirect.find_by(redirect_config_id: @project.redirect_config.id, platform: "ios", variation: "phone")
    assert_not_nil redirect, "redirect must be created in DB"
    assert_equal "https://ios.example.com", redirect.fallback_url, "fallback_url must persist"
    assert redirect.enabled, "redirect must be enabled"
  end

  # --- Validation Errors ---

  test "set redirect with invalid platform returns 422" do
    put "#{API_PREFIX}/projects/#{@project.id}/redirect_config/redirect",
      params: { platform: "invalid_platform", variation: "phone", fallback_url: "https://x.com", appstore: false, enabled: true },
      headers: @headers
    assert_response :unprocessable_entity
    json = JSON.parse(response.body)
    assert json["error"].present?, "must return error message"
  end

  test "set redirect with invalid variation returns 422" do
    put "#{API_PREFIX}/projects/#{@project.id}/redirect_config/redirect",
      params: { platform: "ios", variation: "invalid_variation", fallback_url: "https://x.com", appstore: false, enabled: true },
      headers: @headers
    assert_response :unprocessable_entity
  end

  # --- Cross-Tenant ---

  test "access another instance project redirect config returns 403 with no data leak" do
    get "#{API_PREFIX}/projects/#{@project_two.id}/redirect_config", headers: @headers
    assert_response :forbidden
    json = JSON.parse(response.body)
    assert_equal "Forbidden", json["error"]
    assert_not json.key?("redirect_config"), "403 must not leak redirect data"
  end
end
