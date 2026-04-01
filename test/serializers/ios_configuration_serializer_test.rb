require "test_helper"

class IosConfigurationSerializerTest < ActiveSupport::TestCase
  fixtures :ios_configurations, :applications, :instances, :ios_push_configurations

  # ---------------------------------------------------------------------------
  # 1. VALUE VERIFICATION — assert_equal for every attribute
  # ---------------------------------------------------------------------------

  test "serializes ios_configuration one with correct attribute values" do
    config = ios_configurations(:one)
    result = IosConfigurationSerializer.serialize(config)

    assert_equal "ABC123",          result["app_prefix"]
    assert_equal "com.test.iosapp", result["bundle_id"]
    assert_equal false,             result["tablet_enabled"]
  end

  # ---------------------------------------------------------------------------
  # 2. NESTED PUSH_CONFIGURATION — verify actual values
  # ---------------------------------------------------------------------------

  test "nested push_configuration is a hash with certificate value" do
    config = ios_configurations(:one)
    result = IosConfigurationSerializer.serialize(config)
    push_config = config.ios_push_configuration

    assert_not_nil push_config, "Expected ios_push_configuration fixture to exist"
    assert_instance_of Hash, result["push_configuration"]

    # Certificate is not attached in fixture, so it should be nil
    assert_not push_config.certificate.attached?
    assert_nil result["push_configuration"]["certificate"]
  end

  # ---------------------------------------------------------------------------
  # 3. NESTED SERVER_API_KEY — nil when no fixture exists
  # ---------------------------------------------------------------------------

  test "server_api_key is nil when no ios_server_api_key exists" do
    config = ios_configurations(:one)
    result = IosConfigurationSerializer.serialize(config)

    assert_nil result["server_api_key"]
  end

  test "push_configuration exists while server_api_key is nil" do
    config = ios_configurations(:one)
    result = IosConfigurationSerializer.serialize(config)

    assert_instance_of Hash, result["push_configuration"]
    assert_nil result["server_api_key"]
  end

  # ---------------------------------------------------------------------------
  # 4. EXCLUSION — internal fields must NOT appear
  # ---------------------------------------------------------------------------

  test "excludes updated_at created_at id and application_id" do
    result = IosConfigurationSerializer.serialize(ios_configurations(:one))

    %w[updated_at created_at id application_id].each do |field|
      assert_not_includes result.keys, field,
        "Expected serialized output to exclude '#{field}'"
    end
  end

  test "top-level keys are exactly app_prefix bundle_id tablet_enabled push_configuration server_api_key" do
    result = IosConfigurationSerializer.serialize(ios_configurations(:one))

    expected_keys = %w[app_prefix bundle_id push_configuration server_api_key tablet_enabled]
    assert_equal expected_keys, result.keys.sort
  end

  test "exactly five keys are present" do
    result = IosConfigurationSerializer.serialize(ios_configurations(:one))

    assert_equal 5, result.keys.size
  end

  # ---------------------------------------------------------------------------
  # 5. NIL HANDLING
  # ---------------------------------------------------------------------------

  test "returns nil for nil input" do
    assert_nil IosConfigurationSerializer.serialize(nil)
  end

  test "push_configuration is nil when association is missing" do
    config = ios_configurations(:one)
    config.stub(:ios_push_configuration, nil) do
      result = IosConfigurationSerializer.serialize(config)
      assert_nil result["push_configuration"]
    end
  end

  # ---------------------------------------------------------------------------
  # 6. COLLECTION HANDLING
  # ---------------------------------------------------------------------------

  test "serializes a collection with single item and correct values" do
    result = IosConfigurationSerializer.serialize([ios_configurations(:one)])

    assert_equal 1, result.size
    assert_equal "com.test.iosapp", result[0]["bundle_id"]
    assert_equal "ABC123",          result[0]["app_prefix"]
    assert_equal false,             result[0]["tablet_enabled"]
  end

  test "serializes empty collection as empty array" do
    result = IosConfigurationSerializer.serialize([])
    assert_equal [], result
  end
end
