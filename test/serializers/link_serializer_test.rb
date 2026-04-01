require "test_helper"

class LinkSerializerTest < ActiveSupport::TestCase
  fixtures :links, :domains, :projects, :instances, :redirect_configs, :custom_redirects

  # ---------------------------------------------------------------------------
  # 1. VALUE VERIFICATION -- assert_equal for every declared attribute
  # ---------------------------------------------------------------------------
  test "serializes every declared attribute with correct values" do
    link = links(:basic_link)
    result = LinkSerializer.serialize(link)

    assert_equal link.id,                      result["id"]
    assert_equal "Spring Campaign Link", result["name"]
    assert_equal "test-path",                  result["path"]
    assert_equal "Test Link",                  result["title"]
    assert_equal "A test link",                result["subtitle"]
    assert_equal true,                         result["active"]
    assert_equal false,                        result["sdk_generated"]
    assert_equal '[{"key": "value"}]',             result["data"]
    assert_equal ["promo", "social"],           result["tags"]
    assert_nil result["show_preview_ios"]
    assert_nil result["show_preview_android"]
    assert_nil result["ads_platform"]
    assert_equal "ios",                        result["generated_from_platform"]
    assert_equal "email",                      result["tracking_source"]
    assert_equal "newsletter",                 result["tracking_medium"]
    assert_equal "spring2026",                 result["tracking_campaign"]
    assert_nil result["visitor_id"]
    assert_nil result["campaign_id"]
  end

  # ---------------------------------------------------------------------------
  # 1b. Default mode includes computed fields with real values
  # ---------------------------------------------------------------------------
  test "default mode includes image access_path and nested custom redirects with values" do
    link = links(:basic_link)
    result = LinkSerializer.serialize(link)

    assert_nil result["image"]
    assert_equal link.access_path,             result["access_path"]
    assert_equal "https://example.sqd.link/test-path", result["access_path"]

    # iOS custom redirect
    ios_redirect = result["ios_custom_redirect"]
    assert_not_nil ios_redirect
    assert_equal "https://example.com/ios-custom", ios_redirect["url"]
    assert_equal true,                             ios_redirect["open_app_if_installed"]

    # Android custom redirect
    android_redirect = result["android_custom_redirect"]
    assert_not_nil android_redirect
    assert_equal "https://example.com/android-custom", android_redirect["url"]
    assert_equal false,                                android_redirect["open_app_if_installed"]

    # Desktop custom redirect
    desktop_redirect = result["desktop_custom_redirect"]
    assert_not_nil desktop_redirect
    assert_equal "https://example.com/desktop-custom", desktop_redirect["url"]
    assert_equal false,                                desktop_redirect["open_app_if_installed"]
  end

  # ---------------------------------------------------------------------------
  # 2. EXCLUSION -- internal fields must NOT appear
  # ---------------------------------------------------------------------------
  test "excludes created_at redirect_config_id domain_id and image_url" do
    link = links(:basic_link)
    result = LinkSerializer.serialize(link)

    %w[created_at redirect_config_id domain_id image_url].each do |field|
      assert_not_includes result.keys, field
    end
  end

  # ---------------------------------------------------------------------------
  # 3. NIL HANDLING -- returns nil for nil input
  # ---------------------------------------------------------------------------
  test "returns nil for nil input" do
    assert_nil LinkSerializer.serialize(nil)
  end

  # ---------------------------------------------------------------------------
  # 4. COLLECTION HANDLING -- verify size AND distinct values
  # ---------------------------------------------------------------------------
  test "serializes a collection with correct size and distinct paths" do
    link_a = links(:basic_link)
    link_b = links(:second_link)
    results = LinkSerializer.serialize([link_a, link_b])

    assert_equal 2, results.size

    paths = results.map { |r| r["path"] }
    assert_includes paths, "test-path"
    assert_includes paths, "second-path"
    assert_equal paths.uniq.size, paths.size
  end

  test "empty collection returns empty array" do
    assert_equal [], LinkSerializer.serialize([])
  end

  # ---------------------------------------------------------------------------
  # 5. SLIM MODE -- excludes computed fields, keeps declared attributes
  # ---------------------------------------------------------------------------
  test "slim mode excludes image access_path and all custom redirects" do
    link = links(:basic_link)
    result = LinkSerializer.serialize(link, slim: true)

    %w[image access_path ios_custom_redirect android_custom_redirect desktop_custom_redirect].each do |field|
      assert_not_includes result.keys, field
    end

    # Declared attributes are still present in slim mode
    assert_equal "test-path",   result["path"]
    assert_equal "Test Link",   result["title"]
    assert_equal "A test link", result["subtitle"]
  end

  test "slim mode still excludes internal fields" do
    link = links(:basic_link)
    result = LinkSerializer.serialize(link, slim: true)

    %w[created_at redirect_config_id domain_id image_url].each do |field|
      assert_not_includes result.keys, field
    end
  end

  # ---------------------------------------------------------------------------
  # 6. EDGE CASES -- link without custom redirects
  # ---------------------------------------------------------------------------
  test "link without custom redirects returns nil for each custom redirect" do
    link = links(:second_link)
    result = LinkSerializer.serialize(link)

    assert_nil result["ios_custom_redirect"]
    assert_nil result["android_custom_redirect"]
    assert_nil result["desktop_custom_redirect"]
  end
end
