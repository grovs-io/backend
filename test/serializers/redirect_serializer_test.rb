require "test_helper"

class RedirectSerializerTest < ActiveSupport::TestCase
  fixtures :redirects, :redirect_configs, :applications, :projects, :instances

  # ---------------------------------------------------------------------------
  # 1. VALUE VERIFICATION
  # ---------------------------------------------------------------------------

  test "serializes ios_phone_redirect with correct attribute values" do
    redirect = redirects(:ios_phone_redirect)
    result = RedirectSerializer.serialize(redirect)

    assert_equal redirect_configs(:one).id, result["redirect_config_id"]
    assert_equal "ios",                       result["platform"]
    assert_equal "phone",                     result["variation"]
    assert_equal true,                        result["enabled"]
    assert_equal true,                        result["appstore"]
    assert_nil                                result["fallback_url"]
  end

  test "serializes android_phone_redirect with correct attribute values" do
    redirect = redirects(:android_phone_redirect)
    result = RedirectSerializer.serialize(redirect)

    assert_equal redirect.redirect_config_id,     result["redirect_config_id"]
    assert_equal "android",                        result["platform"]
    assert_equal "phone",                          result["variation"]
    assert_equal true,                             result["enabled"]
    assert_equal false,                            result["appstore"]
    assert_equal "https://example.com/fallback",   result["fallback_url"]
  end

  # ---------------------------------------------------------------------------
  # 2. EXCLUSION — internal fields must NOT appear
  # ---------------------------------------------------------------------------

  test "excludes id application_id created_at and updated_at" do
    result = RedirectSerializer.serialize(redirects(:ios_phone_redirect))

    %w[id application_id created_at updated_at].each do |field|
      assert_not_includes result.keys, field
    end
  end

  # ---------------------------------------------------------------------------
  # 3. NIL HANDLING
  # ---------------------------------------------------------------------------

  test "returns nil for nil input" do
    assert_nil RedirectSerializer.serialize(nil)
  end

  test "fallback_url is nil when not set in fixture" do
    result = RedirectSerializer.serialize(redirects(:ios_phone_redirect))

    assert result.key?("fallback_url"), "Expected key 'fallback_url' to be present"
    assert_nil result["fallback_url"]
  end

  # ---------------------------------------------------------------------------
  # 4. COLLECTION HANDLING — verify size AND distinct values
  # ---------------------------------------------------------------------------

  test "serializes a collection with correct size and distinct platforms" do
    result = RedirectSerializer.serialize([redirects(:ios_phone_redirect), redirects(:android_phone_redirect)])

    assert_equal 2, result.size
    assert_equal "ios",     result[0]["platform"]
    assert_equal "android", result[1]["platform"]
    assert_equal true,      result[0]["appstore"]
    assert_equal false,     result[1]["appstore"]
    assert_nil              result[0]["fallback_url"]
    assert_equal "https://example.com/fallback", result[1]["fallback_url"]
  end

  test "collection items share the same redirect_config_id" do
    result = RedirectSerializer.serialize([redirects(:ios_phone_redirect), redirects(:android_phone_redirect)])

    config_ids = result.map { |r| r["redirect_config_id"] }.uniq
    assert_equal 1, config_ids.size, "Both redirects should belong to the same redirect_config"
  end

  # ---------------------------------------------------------------------------
  # 5. EDGE CASES
  # ---------------------------------------------------------------------------

  test "only exposes exactly six keys" do
    result = RedirectSerializer.serialize(redirects(:ios_phone_redirect))

    expected_keys = %w[appstore enabled fallback_url platform redirect_config_id variation]
    assert_equal expected_keys, result.keys.sort
    assert_equal 6, result.keys.size
  end

  test "appstore and enabled fields are booleans" do
    result = RedirectSerializer.serialize(redirects(:ios_phone_redirect))

    assert_instance_of TrueClass, result["appstore"]
    assert_instance_of TrueClass, result["enabled"]
  end

  test "serializes empty collection as empty array" do
    result = RedirectSerializer.serialize([])
    assert_equal [], result
  end
end
