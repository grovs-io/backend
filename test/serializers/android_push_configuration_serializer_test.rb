require "test_helper"

class AndroidPushConfigurationSerializerTest < ActiveSupport::TestCase
  fixtures :android_push_configurations, :android_configurations, :applications, :instances

  # ---------------------------------------------------------------------------
  # 1. VALUE VERIFICATION -- assert_equal for every declared attribute
  # ---------------------------------------------------------------------------
  test "serializes firebase_project_id with correct value" do
    config = android_push_configurations(:one)
    result = AndroidPushConfigurationSerializer.serialize(config)

    assert_equal "my-firebase-project-12345", result["firebase_project_id"]
  end

  test "serializes firebase_project_id when set" do
    config = android_push_configurations(:one)
    config.update_column(:firebase_project_id, "my-firebase-project")
    config.reload
    result = AndroidPushConfigurationSerializer.serialize(config)

    assert_equal "my-firebase-project", result["firebase_project_id"]
  end

  test "certificate is nil when no certificate is attached" do
    config = android_push_configurations(:one)
    result = AndroidPushConfigurationSerializer.serialize(config)

    assert_includes result.keys, "certificate"
    assert_nil result["certificate"]
  end

  test "certificate returns filename when certificate is attached" do
    config = android_push_configurations(:one)
    config.certificate.attach(
      io: StringIO.new("fake-cert-data"),
      filename: "service-account.json",
      content_type: "application/json"
    )
    result = AndroidPushConfigurationSerializer.serialize(config)

    assert_equal "service-account.json", result["certificate"]
  end

  # ---------------------------------------------------------------------------
  # 2. EXCLUSION -- internal fields must NOT appear
  # ---------------------------------------------------------------------------
  test "excludes updated_at created_at id android_configuration_id and name" do
    config = android_push_configurations(:one)
    result = AndroidPushConfigurationSerializer.serialize(config)

    %w[updated_at created_at id android_configuration_id name].each do |field|
      assert_not_includes result.keys, field
    end
  end

  # ---------------------------------------------------------------------------
  # 3. NIL HANDLING -- returns nil for nil input
  # ---------------------------------------------------------------------------
  test "returns nil for nil input" do
    assert_nil AndroidPushConfigurationSerializer.serialize(nil)
  end

  # ---------------------------------------------------------------------------
  # 4. COLLECTION HANDLING -- verify size
  # ---------------------------------------------------------------------------
  test "serializes a collection with correct size" do
    config = android_push_configurations(:one)
    results = AndroidPushConfigurationSerializer.serialize([config])

    assert_equal 1, results.size
    assert_kind_of Hash, results.first
    assert_equal "my-firebase-project-12345", results.first["firebase_project_id"]
    assert_includes results.first.keys, "certificate"
  end

  test "empty collection returns empty array" do
    assert_equal [], AndroidPushConfigurationSerializer.serialize([])
  end

  # ---------------------------------------------------------------------------
  # 5. EDGE CASES -- output keys and fixture name excluded
  # ---------------------------------------------------------------------------
  test "output contains only firebase_project_id and certificate keys" do
    config = android_push_configurations(:one)
    result = AndroidPushConfigurationSerializer.serialize(config)

    assert_equal %w[certificate firebase_project_id], result.keys.sort
  end

  test "name from fixture is excluded even though it exists on the model" do
    config = android_push_configurations(:one)
    assert_equal "FCM Config", config.name

    result = AndroidPushConfigurationSerializer.serialize(config)
    assert_not_includes result.keys, "name"
  end
end
