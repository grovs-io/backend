require "test_helper"

class RedirectConfigSerializerTest < ActiveSupport::TestCase
  fixtures :redirect_configs, :redirects, :projects, :instances, :applications

  test "serializes top-level attributes with correct values" do
    rc = redirect_configs(:one)
    result = RedirectConfigSerializer.serialize(rc)

    assert_equal "https://example.com/fallback", result["default_fallback"]
    assert_equal false, result["show_preview_ios"]
    assert_equal false, result["show_preview_android"]
  end

  test "ios nested hash contains phone and tablet redirect objects" do
    rc = redirect_configs(:one)
    result = RedirectConfigSerializer.serialize(rc)

    assert_kind_of Hash, result["ios"]
    assert_includes result["ios"].keys, "phone"
    assert_includes result["ios"].keys, "tablet"

    # ios_phone_redirect fixture exists: verify it is the correct Redirect record
    phone_redirect = result["ios"]["phone"]
    assert_not_nil phone_redirect, "Expected ios phone redirect to be present"
    assert_equal "ios", phone_redirect.platform
    assert_equal "phone", phone_redirect.variation
    assert_equal true, phone_redirect.enabled
    # No ios_tablet_redirect fixture exists, so it should be nil
    assert_nil result["ios"]["tablet"]
  end

  test "android nested hash contains phone and tablet redirect objects" do
    rc = redirect_configs(:one)
    result = RedirectConfigSerializer.serialize(rc)

    assert_kind_of Hash, result["android"]
    assert_includes result["android"].keys, "phone"
    assert_includes result["android"].keys, "tablet"

    # android_phone_redirect fixture exists: verify it is the correct Redirect record
    phone_redirect = result["android"]["phone"]
    assert_not_nil phone_redirect, "Expected android phone redirect to be present"
    assert_equal "android", phone_redirect.platform
    assert_equal "phone", phone_redirect.variation
    assert_equal "https://example.com/fallback", phone_redirect.fallback_url
    # No android_tablet_redirect fixture exists, so it should be nil
    assert_nil result["android"]["tablet"]
  end

  test "desktop nested hash contains all redirect object" do
    rc = redirect_configs(:one)
    result = RedirectConfigSerializer.serialize(rc)

    assert_kind_of Hash, result["desktop"]
    assert_includes result["desktop"].keys, "all"

    # desktop_redirect fixture exists: verify it is the correct Redirect record
    all_redirect = result["desktop"]["all"]
    assert_not_nil all_redirect, "Expected desktop all redirect to be present"
    assert_equal "desktop", all_redirect.platform
    assert_equal "desktop", all_redirect.variation
    assert_equal "https://example.com/desktop-fallback", all_redirect.fallback_url
  end

  test "excludes internal fields" do
    rc = redirect_configs(:one)
    result = RedirectConfigSerializer.serialize(rc)

    %w[updated_at created_at id project_id].each do |field|
      assert_not_includes result.keys, field, "expected #{field} to be excluded"
    end
  end

  test "returns nil for nil input" do
    assert_nil RedirectConfigSerializer.serialize(nil)
  end

  test "serializes a collection" do
    rc = redirect_configs(:one)
    result = RedirectConfigSerializer.serialize([rc, rc])

    assert_equal 2, result.size
    assert_kind_of Hash, result[0]["ios"]
    assert_kind_of Hash, result[1]["ios"]
  end
end
