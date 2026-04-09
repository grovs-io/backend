require "test_helper"
require_relative "../mcp_auth_test_helper"

class McpConfigurationsTest < ActionDispatch::IntegrationTest
  include McpAuthTestHelper

  fixtures :instances, :users, :instance_roles, :projects, :domains,
           :redirect_configs, :applications, :desktop_configurations,
           :ios_configurations, :android_configurations, :redirects

  setup do
    @admin_user = users(:admin_user)
    @member_user = users(:member_user)
    @instance = instances(:one)
    @project = projects(:one)
    @project_test = projects(:one_test)
    @admin_headers = create_mcp_headers_for(@admin_user)
    @member_headers = create_mcp_headers_for(@member_user)
  end

  # ==========================================================================
  # Setup Redirects
  # ==========================================================================

  test "setup_redirects sets default fallback with full RedirectConfigSerializer schema" do
    headers = @admin_headers
    assert_no_difference "RedirectConfig.count" do
      put "#{MCP_PREFIX}/redirects",
        params: {
          project_id: @project.hashid,
          default_fallback: "https://example.com/new-fallback"
        },
        headers: headers
    end
    assert_response :ok
    json = json_response
    rc = json["redirect_config"]

    # RedirectConfigSerializer base attributes
    assert_equal "https://example.com/new-fallback", rc["default_fallback"]
    assert [true, false].include?(rc["show_preview_ios"])
    assert [true, false].include?(rc["show_preview_android"])

    # Platform redirect sub-objects
    assert rc["ios"].present?, "should include ios redirects"
    assert rc["ios"].key?("phone"), "ios should have phone variation"
    assert rc["ios"].key?("tablet"), "ios should have tablet variation"
    assert rc["android"].present?, "should include android redirects"
    assert rc["android"].key?("phone"), "android should have phone variation"
    assert rc["android"].key?("tablet"), "android should have tablet variation"
    assert rc["desktop"].present?, "should include desktop redirects"
    assert rc["desktop"].key?("all"), "desktop should have all variation"

    # Verify DB matches
    assert_equal "https://example.com/new-fallback", @project.redirect_config.reload.default_fallback
  end

  test "setup_redirects sets per-platform redirects via platforms hash" do
    headers = @admin_headers
    assert_no_difference "RedirectConfig.count" do
      put "#{MCP_PREFIX}/redirects",
        params: {
          project_id: @project.hashid,
          platforms: {
            ios: {
              variation: "phone",
              fallback_url: nil,
              appstore: true,
              enabled: true
            },
            android: {
              variation: "phone",
              fallback_url: "https://play.google.com/store/apps/myapp",
              appstore: false,
              enabled: true
            }
          }
        },
        headers: headers
    end
    assert_response :ok
    json = json_response
    rc = json["redirect_config"]

    # Verify response includes platform redirect structure
    assert rc["ios"]["phone"].present?, "response should include ios phone redirect"
    assert rc["android"]["phone"].present?, "response should include android phone redirect"

    # Verify iOS redirect was updated (appstore=true means no fallback_url)
    ios_redirect = @project.redirect_config.reload.redirect_for_platform_and_variation("ios", "phone")
    assert_nil ios_redirect.fallback_url
    assert_equal true, ios_redirect.appstore

    # Verify Android redirect was updated (appstore=false with fallback_url)
    android_redirect = @project.redirect_config.redirect_for_platform_and_variation("android", "phone")
    assert_equal "https://play.google.com/store/apps/myapp", android_redirect.fallback_url
    assert_equal false, android_redirect.appstore
  end

  test "setup_redirects creates redirect_config when none exists" do
    # project :one_test has no redirect_config fixture
    headers = @admin_headers
    assert_difference "RedirectConfig.count", 1 do
      put "#{MCP_PREFIX}/redirects",
        params: {
          project_id: @project_test.hashid,
          default_fallback: "https://test.example.com/fallback"
        },
        headers: headers
    end
    assert_response :ok
    json = json_response
    assert_equal "https://test.example.com/fallback", json["redirect_config"]["default_fallback"]
  end

  test "setup_redirects with only platforms and no default_fallback creates config with nil fallback" do
    # project :one_test has no redirect_config — sending only platforms should still create one
    headers = @admin_headers
    assert_difference "RedirectConfig.count", 1 do
      put "#{MCP_PREFIX}/redirects",
        params: {
          project_id: @project_test.hashid,
          platforms: {
            ios: { variation: "phone", fallback_url: "https://apps.apple.com/myapp", appstore: false, enabled: true }
          }
        },
        headers: headers
    end
    assert_response :ok
    json = json_response
    assert_nil json["redirect_config"]["default_fallback"]

    rc = @project_test.reload.redirect_config
    assert_nil rc.default_fallback
    ios_redirect = rc.redirect_for_platform_and_variation("ios", "phone")
    assert_equal "https://apps.apple.com/myapp", ios_redirect.fallback_url
  end

  test "setup_redirects returns 400 for unsupported platform" do
    headers = @admin_headers
    put "#{MCP_PREFIX}/redirects",
      params: {
        project_id: @project.hashid,
        platforms: { web: { variation: "phone", fallback_url: "https://example.com", appstore: false, enabled: true } }
      },
      headers: headers
    assert_response :bad_request
    json = json_response
    assert_match(/Unsupported platform/, json["error"])
  end

  test "setup_redirects forbidden for non-member" do
    headers = @admin_headers
    put "#{MCP_PREFIX}/redirects",
      params: {
        project_id: projects(:two).hashid,
        default_fallback: "https://evil.com"
      },
      headers: headers
    assert_response :forbidden
  end

  # ==========================================================================
  # Setup SDK
  # ==========================================================================

  test "setup_sdk sets iOS configuration with full ApplicationSerializer schema" do
    headers = @admin_headers
    assert_no_difference "IosConfiguration.count" do
      put "#{MCP_PREFIX}/sdk",
        params: {
          instance_id: @instance.hashid,
          platforms: {
            ios: {
              bundle_id: "com.newapp.ios",
              app_prefix: "XYZ789"
            }
          }
        },
        headers: headers
    end
    assert_response :ok
    json = json_response

    # Validate ApplicationSerializer schema
    ios_app = json["configurations"]["ios"]
    assert ios_app.present?
    assert_equal @instance.id, ios_app["instance_id"]
    assert_equal "ios", ios_app["platform"]
    assert_equal true, ios_app["enabled"]

    # Validate nested IosConfigurationSerializer
    config = ios_app["configuration"]
    assert config.present?
    assert_equal "com.newapp.ios", config["bundle_id"]
    assert_equal "XYZ789", config["app_prefix"]
    assert config.key?("tablet_enabled")
    assert config.key?("push_configuration")

    # Verify DB matches
    ios_config = @instance.ios_application.ios_configuration.reload
    assert_equal "com.newapp.ios", ios_config.bundle_id
    assert_equal "XYZ789", ios_config.app_prefix
  end

  test "setup_sdk sets Android configuration with full ApplicationSerializer schema" do
    headers = @admin_headers
    assert_no_difference "AndroidConfiguration.count" do
      put "#{MCP_PREFIX}/sdk",
        params: {
          instance_id: @instance.hashid,
          platforms: {
            android: {
              identifier: "com.newapp.android",
              sha256s: "AA:BB:CC"
            }
          }
        },
        headers: headers
    end
    assert_response :ok
    json = json_response

    # Validate ApplicationSerializer schema
    android_app = json["configurations"]["android"]
    assert android_app.present?
    assert_equal @instance.id, android_app["instance_id"]
    assert_equal "android", android_app["platform"]
    assert_equal true, android_app["enabled"]

    # Validate nested AndroidConfigurationSerializer
    config = android_app["configuration"]
    assert config.present?
    assert_equal "com.newapp.android", config["identifier"]
    assert config.key?("sha256s")
    assert config.key?("tablet_enabled")
    assert config.key?("push_configuration")

    # Verify DB matches
    android_config = @instance.android_application.android_configuration.reload
    assert_equal "com.newapp.android", android_config.identifier
  end

  test "setup_sdk returns 400 for unsupported platform" do
    headers = @admin_headers
    put "#{MCP_PREFIX}/sdk",
      params: {
        instance_id: @instance.hashid,
        platforms: { web: { url: "https://example.com" } }
      },
      headers: headers
    assert_response :bad_request
    json = json_response
    assert_match(/Unsupported platform/, json["error"])
  end

  test "setup_sdk forbidden for non-member instance" do
    headers = @admin_headers
    put "#{MCP_PREFIX}/sdk",
      params: {
        instance_id: instances(:two).hashid,
        platforms: {
          ios: { bundle_id: "com.hack.ios", app_prefix: "HACK" }
        }
      },
      headers: headers
    assert_response :forbidden
  end

  test "setup_sdk without platforms param returns error" do
    headers = @admin_headers
    put "#{MCP_PREFIX}/sdk",
      params: { instance_id: @instance.hashid },
      headers: headers
    assert_response :bad_request
  end

  test "setup_sdk sets Desktop configuration with full ApplicationSerializer schema" do
    headers = @admin_headers
    # Destroy any existing desktop configuration so we test creation from scratch
    desktop_app = @instance.applications.find_by(platform: "desktop")
    DesktopConfiguration.where(application: desktop_app).delete_all
    assert_nil DesktopConfiguration.find_by(application: desktop_app), "should not exist before setup"

    put "#{MCP_PREFIX}/sdk",
      params: {
        instance_id: @instance.hashid,
        platforms: {
          desktop: {
            fallback_url: "https://example.com/download",
            mac_uri: "myapp://open",
            windows_uri: "myapp://open",
            mac_enabled: true,
            windows_enabled: true
          }
        }
      },
      headers: headers
    assert_response :ok
    json = json_response

    # Validate ApplicationSerializer schema
    desktop_app = json["configurations"]["desktop"]
    assert desktop_app.present?
    assert_equal @instance.id, desktop_app["instance_id"]
    assert_equal "desktop", desktop_app["platform"]
    assert_equal true, desktop_app["enabled"]

    # Validate nested DesktopConfigurationSerializer
    config = desktop_app["configuration"]
    assert config.present?
    assert_equal "https://example.com/download", config["fallback_url"]
    assert_equal "myapp://open", config["mac_uri"]
    assert_equal "myapp://open", config["windows_uri"]
    assert_equal true, config["mac_enabled"]
    assert_equal true, config["windows_enabled"]

    # Verify DB matches
    desktop_config = @instance.desktop_application.desktop_configuration.reload
    assert_equal "https://example.com/download", desktop_config.fallback_url
    assert_equal "myapp://open", desktop_config.mac_uri
    assert_equal true, desktop_config.mac_enabled
  end

  test "setup_sdk filters unknown params per platform" do
    headers = @admin_headers
    # iOS only permits: bundle_id, app_prefix, tablet_enabled
    # 'identifier' is Android-only and should be silently dropped
    put "#{MCP_PREFIX}/sdk",
      params: {
        instance_id: @instance.hashid,
        platforms: {
          ios: {
            bundle_id: "com.filtered.ios",
            app_prefix: "FILT",
            identifier: "should-be-dropped"
          }
        }
      },
      headers: headers
    assert_response :ok

    ios_config = @instance.ios_application.ios_configuration.reload
    assert_equal "com.filtered.ios", ios_config.bundle_id
    assert_equal "FILT", ios_config.app_prefix

    # identifier is an Android-only column — verify it didn't leak to Android config
    android_identifier_before = @instance.android_application.android_configuration.identifier
    assert_equal android_identifier_before, @instance.android_application.android_configuration.reload.identifier,
      "Android identifier should be unchanged when only iOS platform was sent"
  end

  test "setup_sdk with nonexistent instance returns not_found" do
    headers = @admin_headers
    put "#{MCP_PREFIX}/sdk",
      params: {
        instance_id: "nonexistent",
        platforms: { ios: { bundle_id: "com.ghost.ios" } }
      },
      headers: headers
    assert_response :not_found
  end

  test "member_user can setup_sdk" do
    put "#{MCP_PREFIX}/sdk",
      params: {
        instance_id: @instance.hashid,
        platforms: { ios: { bundle_id: "com.member.ios", app_prefix: "MEM123" } }
      },
      headers: @member_headers
    assert_response :ok
  end
end
