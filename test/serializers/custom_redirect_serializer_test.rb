require "test_helper"

class CustomRedirectSerializerTest < ActiveSupport::TestCase
  fixtures :custom_redirects, :links, :domains, :projects, :instances

  # ---------------------------------------------------------------------------
  # 1. VALUE VERIFICATION
  # ---------------------------------------------------------------------------

  test "serializes ios redirect with correct attribute values" do
    cr = custom_redirects(:ios_redirect_for_basic_link)
    result = CustomRedirectSerializer.serialize(cr)

    assert_equal "https://example.com/ios-custom", result["url"]
    assert_equal true,                              result["open_app_if_installed"]
  end

  test "serializes android redirect with correct attribute values" do
    cr = custom_redirects(:android_redirect_for_basic_link)
    result = CustomRedirectSerializer.serialize(cr)

    assert_equal "https://example.com/android-custom", result["url"]
    assert_equal false,                                 result["open_app_if_installed"]
  end

  # ---------------------------------------------------------------------------
  # 2. EXCLUSION — internal fields must NOT appear
  # ---------------------------------------------------------------------------

  test "excludes created_at updated_at id link_id and platform" do
    result = CustomRedirectSerializer.serialize(custom_redirects(:ios_redirect_for_basic_link))

    %w[created_at updated_at id link_id platform].each do |field|
      assert_not_includes result.keys, field
    end
  end

  # ---------------------------------------------------------------------------
  # 3. NIL HANDLING
  # ---------------------------------------------------------------------------

  test "returns nil for nil input" do
    assert_nil CustomRedirectSerializer.serialize(nil)
  end

  # ---------------------------------------------------------------------------
  # 4. COLLECTION HANDLING — verify size AND distinct values
  # ---------------------------------------------------------------------------

  test "serializes a collection with correct size and distinct urls" do
    redirects = [
      custom_redirects(:ios_redirect_for_basic_link),
      custom_redirects(:android_redirect_for_basic_link)
    ]
    result = CustomRedirectSerializer.serialize(redirects)

    assert_equal 2, result.size
    assert_equal "https://example.com/ios-custom",     result[0]["url"]
    assert_equal "https://example.com/android-custom",  result[1]["url"]
    assert_equal true,                                  result[0]["open_app_if_installed"]
    assert_equal false,                                 result[1]["open_app_if_installed"]
  end

  # ---------------------------------------------------------------------------
  # 5. EDGE CASES
  # ---------------------------------------------------------------------------

  test "only exposes exactly two keys" do
    result = CustomRedirectSerializer.serialize(custom_redirects(:ios_redirect_for_basic_link))

    assert_equal %w[open_app_if_installed url], result.keys.sort
  end

  test "open_app_if_installed is a boolean not a string" do
    result_true = CustomRedirectSerializer.serialize(custom_redirects(:ios_redirect_for_basic_link))
    result_false = CustomRedirectSerializer.serialize(custom_redirects(:android_redirect_for_basic_link))

    assert_instance_of TrueClass, result_true["open_app_if_installed"]
    assert_instance_of FalseClass, result_false["open_app_if_installed"]
  end

  test "serializes empty collection as empty array" do
    result = CustomRedirectSerializer.serialize([])
    assert_equal [], result
  end
end
