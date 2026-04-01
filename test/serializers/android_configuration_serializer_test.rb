require "test_helper"

class AndroidConfigurationSerializerTest < ActiveSupport::TestCase
  fixtures :android_configurations, :applications, :instances,
           :android_push_configurations, :android_server_api_keys

  test "serializes declared attributes with correct values" do
    config = android_configurations(:one)
    result = AndroidConfigurationSerializer.serialize(config)

    assert_equal "com.test.androidapp", result["identifier"]
    assert_equal ["AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99"], result["sha256s"]
    assert_equal false, result["tablet_enabled"]
  end

  test "push_configuration is serialized via AndroidPushConfigurationSerializer" do
    config = android_configurations(:one)
    result = AndroidConfigurationSerializer.serialize(config)

    push_config = result["push_configuration"]
    assert_kind_of Hash, push_config

    assert_equal "my-firebase-project-12345", push_config["firebase_project_id"]
    # certificate is not attached in fixture, so should be nil
    assert_includes push_config.keys, "certificate"
  end

  test "server_api_key is serialized via AndroidServerApiKeySerializer" do
    config = android_configurations(:one)
    result = AndroidConfigurationSerializer.serialize(config)

    server_key = result["server_api_key"]
    assert_kind_of Hash, server_key

    # No file attached in fixture, so file should be nil
    assert_includes server_key.keys, "file"
    assert_nil server_key["file"]
  end

  test "push_configuration is nil when no push config exists" do
    config = android_configurations(:one)
    config.android_push_configuration.destroy
    config.reload

    result = AndroidConfigurationSerializer.serialize(config)

    assert_nil result["push_configuration"]
  end

  test "server_api_key is nil when no server api key exists" do
    config = android_configurations(:one)
    config.android_server_api_key.destroy
    config.reload

    result = AndroidConfigurationSerializer.serialize(config)

    assert_nil result["server_api_key"]
  end

  test "excludes internal fields" do
    config = android_configurations(:one)
    result = AndroidConfigurationSerializer.serialize(config)

    %w[updated_at created_at id application_id].each do |field|
      assert_not_includes result.keys, field, "expected #{field} to be excluded"
    end
  end

  test "returns nil for nil input" do
    assert_nil AndroidConfigurationSerializer.serialize(nil)
  end

  test "serializes a collection" do
    config = android_configurations(:one)
    result = AndroidConfigurationSerializer.serialize([config, config])

    assert_equal 2, result.size
    assert_equal "com.test.androidapp", result[0]["identifier"]
    assert_equal "com.test.androidapp", result[1]["identifier"]
  end
end
