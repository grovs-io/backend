require "test_helper"

class ApplicationSerializerTest < ActiveSupport::TestCase
  fixtures :applications, :instances, :ios_configurations, :android_configurations,
           :desktop_configurations, :web_configurations, :ios_push_configurations,
           :android_push_configurations, :android_server_api_keys,
           :web_configuration_linked_domains

  # --- iOS platform dispatch ---

  test "ios app dispatches to IosConfigurationSerializer" do
    app = applications(:ios_app)
    result = ApplicationSerializer.serialize(app)

    assert_equal instances(:one).id, result["instance_id"]
    assert_equal "ios", result["platform"]
    assert_equal true, result["enabled"]

    config = result["configuration"]
    assert_kind_of Hash, config
    assert_equal "com.test.iosapp", config["bundle_id"]
    assert_equal "ABC123", config["app_prefix"]
    assert_equal false, config["tablet_enabled"]
  end

  # --- Android platform dispatch ---

  test "android app dispatches to AndroidConfigurationSerializer" do
    app = applications(:android_app)
    result = ApplicationSerializer.serialize(app)

    assert_equal instances(:one).id, result["instance_id"]
    assert_equal "android", result["platform"]
    assert_equal true, result["enabled"]

    config = result["configuration"]
    assert_kind_of Hash, config
    assert_equal "com.test.androidapp", config["identifier"]
    assert_equal false, config["tablet_enabled"]
    assert_includes config.keys, "push_configuration"
    assert_includes config.keys, "server_api_key"
  end

  # --- Desktop platform dispatch ---

  test "desktop app dispatches to DesktopConfigurationSerializer" do
    app = applications(:desktop_app)
    result = ApplicationSerializer.serialize(app)

    assert_equal instances(:one).id, result["instance_id"]
    assert_equal "desktop", result["platform"]
    assert_equal true, result["enabled"]

    config = result["configuration"]
    assert_kind_of Hash, config
    assert_equal "https://example.com/desktop", config["fallback_url"]
    assert_equal true, config["generated_page"]
  end

  # --- Web platform dispatch ---

  test "web app dispatches to WebConfigurationSerializer" do
    app = applications(:web_app)
    result = ApplicationSerializer.serialize(app)

    assert_equal instances(:one).id, result["instance_id"]
    assert_equal "web", result["platform"]
    assert_equal true, result["enabled"]

    config = result["configuration"]
    assert_kind_of Hash, config
    assert_kind_of Array, config["domains"]
  end

  # --- Excludes internal fields ---

  test "excludes updated_at created_at and id" do
    app = applications(:ios_app)
    result = ApplicationSerializer.serialize(app)

    %w[updated_at created_at id].each do |field|
      assert_not_includes result.keys, field, "expected #{field} to be excluded"
    end
  end

  # --- nil handling ---

  test "returns nil for nil input" do
    assert_nil ApplicationSerializer.serialize(nil)
  end

  # --- collection handling ---

  test "serializes a collection" do
    apps = [applications(:ios_app), applications(:android_app), applications(:desktop_app)]
    result = ApplicationSerializer.serialize(apps)

    assert_equal 3, result.size
    assert_equal "ios", result[0]["platform"]
    assert_equal "android", result[1]["platform"]
    assert_equal "desktop", result[2]["platform"]
  end
end
