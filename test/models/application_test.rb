require "test_helper"

class ApplicationTest < ActiveSupport::TestCase
  fixtures :applications, :instances, :ios_configurations, :android_configurations,
           :desktop_configurations, :web_configurations

  # === platform validation ===

  test "valid with a recognized platform" do
    app = applications(:ios_app)
    assert app.valid?
  end

  test "invalid with unrecognized platform" do
    app = applications(:ios_app)
    app.platform = "unknown"
    assert_not app.valid?
    assert app.errors[:platform].any?
  end

  Grovs::Platforms::ALL.each do |platform|
    test "accepts platform #{platform}" do
      app = Application.new(instance: instances(:one), platform: platform)
      assert app.valid?, "Expected platform '#{platform}' to be valid, errors: #{app.errors.full_messages}"
    end
  end

  # === configuration method ===

  test "configuration returns ios_configuration for ios platform" do
    app = applications(:ios_app)
    Rails.cache.delete([app, "configuration"])

    config = app.configuration
    assert_equal ios_configurations(:one), config
  end

  test "configuration returns android_configuration for android platform" do
    app = applications(:android_app)
    Rails.cache.delete([app, "configuration"])

    config = app.configuration
    assert_equal android_configurations(:one), config
  end

  test "configuration returns desktop_configuration for desktop platform" do
    app = applications(:desktop_app)
    Rails.cache.delete([app, "configuration"])

    config = app.configuration
    assert_equal desktop_configurations(:one), config
  end

  test "configuration returns web_configuration for web platform" do
    app = applications(:web_app)
    Rails.cache.delete([app, "configuration"])

    config = app.configuration
    assert_equal web_configurations(:one), config
  end

  test "configuration returns nil for platform with no configuration" do
    app = Application.create!(instance: instances(:two), platform: Grovs::Platforms::IOS)
    Rails.cache.delete([app, "configuration"])

    assert_nil app.configuration
  end

  # === serialization ===

  test "serializer excludes internal fields" do
    app = applications(:ios_app)
    json = ApplicationSerializer.serialize(app)

    assert_nil json["id"]
    assert_nil json["created_at"]
    assert_nil json["updated_at"]
  end

  test "serializer includes configuration" do
    app = applications(:ios_app)
    Rails.cache.delete([app, "configuration"])

    json = ApplicationSerializer.serialize(app)
    assert json.key?("configuration")
  end

  # === clear_configuration_cache ===

  test "clear_configuration_cache runs without error" do
    app = applications(:ios_app)
    # Populate cache by calling configuration
    Rails.cache.delete([app, "configuration"])
    app.configuration

    # clear_configuration_cache should not raise
    assert_nothing_raised do
      app.clear_configuration_cache
    end

    # After clearing, calling configuration again should re-query
    config = app.configuration
    assert_equal ios_configurations(:one), config
  end

  # === configuration cache cleared on destroy ===

  test "destroying ios_configuration clears the application configuration cache" do
    app = applications(:ios_app)
    config = ios_configurations(:one)

    # Populate cache
    Rails.cache.delete([app, "configuration"])
    cached = app.configuration
    assert cached, "Configuration should be cached"

    # Destroy the config — after_destroy should clear the cache
    config.destroy!

    # Cache should be gone — next call returns nil (no config exists)
    assert_nil Rails.cache.read([app, "configuration"]),
      "Configuration cache should be invalidated after destroy"
  end

  test "destroying android_configuration clears the application configuration cache" do
    app = applications(:android_app)
    config = android_configurations(:one)

    Rails.cache.delete([app, "configuration"])
    app.configuration

    config.destroy!

    assert_nil Rails.cache.read([app, "configuration"]),
      "Configuration cache should be invalidated after destroy"
  end

  # === cache_keys_to_clear ===

  test "cache_keys_to_clear includes multi-condition key for instance_id and platform" do
    app = applications(:ios_app)
    expected = app.send(:multi_condition_cache_key, { instance_id: app.instance_id, platform: app.platform })
    keys = app.cache_keys_to_clear
    assert_includes keys, expected
  end

  test "cache_keys_to_clear excludes multi-condition key when instance_id is nil" do
    app = Application.new(platform: Grovs::Platforms::IOS)
    app.instance_id = nil
    keys = app.cache_keys_to_clear
    # Should not contain any multi-condition key for instance_id
    multi_keys = keys.select { |k| k.include?("instance_id") }
    assert_equal 0, multi_keys.count
  end
end
