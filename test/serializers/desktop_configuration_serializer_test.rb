require "test_helper"

class DesktopConfigurationSerializerTest < ActiveSupport::TestCase
  fixtures :desktop_configurations, :applications, :instances

  # ---------------------------------------------------------------------------
  # 1. VALUE VERIFICATION
  # ---------------------------------------------------------------------------

  test "serializes config one with correct attribute values" do
    config = desktop_configurations(:one)
    result = DesktopConfigurationSerializer.serialize(config)

    assert_equal "https://example.com/desktop",  result["fallback_url"]
    assert_equal true,                           result["generated_page"]
    assert_equal true,                           result["mac_enabled"]
    assert_equal "testapp://mac",                result["mac_uri"]
    assert_equal true,                           result["windows_enabled"]
    assert_equal "testapp://windows",            result["windows_uri"]
  end

  # ---------------------------------------------------------------------------
  # 2. EXCLUSION — internal fields must NOT appear
  # ---------------------------------------------------------------------------

  test "excludes updated_at created_at id and application_id" do
    result = DesktopConfigurationSerializer.serialize(desktop_configurations(:one))

    %w[updated_at created_at id application_id].each do |field|
      assert_not_includes result.keys, field
    end
  end

  # ---------------------------------------------------------------------------
  # 3. NIL HANDLING
  # ---------------------------------------------------------------------------

  test "returns nil for nil input" do
    assert_nil DesktopConfigurationSerializer.serialize(nil)
  end

  test "uri fields are serialized with correct values" do
    result = DesktopConfigurationSerializer.serialize(desktop_configurations(:one))

    assert_equal "testapp://mac", result["mac_uri"]
    assert_equal "testapp://windows", result["windows_uri"]
  end

  # ---------------------------------------------------------------------------
  # 4. COLLECTION HANDLING — verify size AND distinct values
  # ---------------------------------------------------------------------------

  test "serializes a single-element collection" do
    result = DesktopConfigurationSerializer.serialize([desktop_configurations(:one)])

    assert_equal 1, result.size
    assert_equal "https://example.com/desktop", result[0]["fallback_url"]
    assert_equal true,                          result[0]["generated_page"]
    assert_equal true,                          result[0]["mac_enabled"]
    assert_equal true,                          result[0]["windows_enabled"]
  end

  # ---------------------------------------------------------------------------
  # 5. EDGE CASES
  # ---------------------------------------------------------------------------

  test "only exposes exactly six keys" do
    result = DesktopConfigurationSerializer.serialize(desktop_configurations(:one))

    expected_keys = %w[fallback_url generated_page mac_enabled mac_uri windows_enabled windows_uri]
    assert_equal expected_keys, result.keys.sort
    assert_equal 6, result.keys.size
  end

  test "boolean defaults are correct types" do
    result = DesktopConfigurationSerializer.serialize(desktop_configurations(:one))

    assert_instance_of TrueClass, result["generated_page"]
    assert_instance_of TrueClass, result["mac_enabled"]
    assert_instance_of TrueClass, result["windows_enabled"]
  end

  test "serializes empty collection as empty array" do
    result = DesktopConfigurationSerializer.serialize([])
    assert_equal [], result
  end
end
