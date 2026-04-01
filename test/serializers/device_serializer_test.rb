require "test_helper"

class DeviceSerializerTest < ActiveSupport::TestCase
  fixtures :devices

  # ---------------------------------------------------------------------------
  # 1. VALUE VERIFICATION
  # ---------------------------------------------------------------------------

  test "serializes ios_device with correct attribute values" do
    device = devices(:ios_device)
    result = DeviceSerializer.serialize(device)

    assert_equal device.id,                    result["id"]
    assert_equal "ios",                        result["platform"]
    assert_equal "iPhone 15 Pro",              result["model"]
    assert_equal "1.5.0",                      result["app_version"]
    assert_equal "2026031901",                 result["build"]
    assert_equal "en",                         result["language"]
    assert_equal "America/New_York",           result["timezone"]
    assert_equal 1179,                         result["screen_width"]
    assert_equal 2556,                         result["screen_height"]
  end

  test "serializes android_device with correct attribute values" do
    device = devices(:android_device)
    result = DeviceSerializer.serialize(device)

    assert_equal device.id,                    result["id"]
    assert_equal "android",                    result["platform"]
    assert_equal "Pixel 8",                    result["model"]
    assert_equal "2.1.0",                      result["app_version"]
    assert_equal "2026031902",                 result["build"]
    assert_equal "es",                         result["language"]
    assert_equal "Europe/Madrid",              result["timezone"]
    assert_equal 1080,                         result["screen_width"]
    assert_equal 2400,                         result["screen_height"]
  end

  # ---------------------------------------------------------------------------
  # 2. EXCLUSION — sensitive fields must NOT appear
  # ---------------------------------------------------------------------------

  test "excludes vendor ip remote_ip user_agent and push_token" do
    result = DeviceSerializer.serialize(devices(:ios_device))

    %w[vendor ip remote_ip user_agent push_token].each do |field|
      assert_not_includes result.keys, field
    end
  end

  test "excludes webgl_renderer and webgl_vendor" do
    result = DeviceSerializer.serialize(devices(:ios_device))

    %w[webgl_renderer webgl_vendor].each do |field|
      assert_not_includes result.keys, field
    end
  end

  # ---------------------------------------------------------------------------
  # 3. NIL HANDLING
  # ---------------------------------------------------------------------------

  test "returns nil for nil input" do
    assert_nil DeviceSerializer.serialize(nil)
  end

  test "nil optional fields are present as keys with nil values" do
    result = DeviceSerializer.serialize(devices(:web_device))

    %w[model app_version build language timezone screen_width screen_height].each do |field|
      assert result.key?(field), "Expected key '#{field}' to be present"
      assert_nil result[field]
    end
  end

  # ---------------------------------------------------------------------------
  # 4. COLLECTION HANDLING — verify size AND distinct values
  # ---------------------------------------------------------------------------

  test "serializes a collection with correct size and distinct platforms" do
    result = DeviceSerializer.serialize([devices(:ios_device), devices(:android_device)])

    assert_equal 2, result.size
    assert_equal "ios",     result[0]["platform"]
    assert_equal "android", result[1]["platform"]
    assert_equal devices(:ios_device).id,     result[0]["id"]
    assert_equal devices(:android_device).id, result[1]["id"]
  end

  # ---------------------------------------------------------------------------
  # 5. EDGE CASES
  # ---------------------------------------------------------------------------

  test "only exposes exactly eleven keys" do
    result = DeviceSerializer.serialize(devices(:ios_device))

    expected_keys = %w[app_version build created_at id language model platform screen_height screen_width timezone updated_at]
    assert_equal expected_keys, result.keys.sort
    assert_equal 11, result.keys.size
  end

  test "collection items each contain all expected keys" do
    result = DeviceSerializer.serialize([devices(:ios_device), devices(:android_device)])

    expected_keys = %w[app_version build created_at id language model platform screen_height screen_width timezone updated_at]
    result.each do |item|
      assert_equal expected_keys, item.keys.sort
    end
  end

  test "serializes empty collection as empty array" do
    result = DeviceSerializer.serialize([])
    assert_equal [], result
  end
end
