require "test_helper"

class QuickLinkSerializerTest < ActiveSupport::TestCase
  fixtures :quick_links, :domains, :projects, :instances

  # ---------------------------------------------------------------------------
  # 1. VALUE VERIFICATION
  # ---------------------------------------------------------------------------

  test "serializes all declared attributes with correct values" do
    ql = quick_links(:basic_quick_link)
    result = QuickLinkSerializer.serialize(ql)

    assert_equal "quick-test", result["path"]
    assert_equal "Quick Link", result["title"]
    assert_equal "A quick link", result["subtitle"]
    assert_equal "https://apps.apple.com/app/id123", result["ios_phone"]
    assert_equal "https://apps.apple.com/app/id123-ipad", result["ios_tablet"]
    assert_equal "https://play.google.com/store/apps/details?id=com.test", result["android_phone"]
    assert_equal "https://play.google.com/store/apps/details?id=com.test.tablet", result["android_tablet"]
    assert_equal "https://example.com/desktop", result["desktop"]
    assert_equal "https://example.com/mac", result["desktop_mac"]
    assert_equal "https://example.com/windows", result["desktop_windows"]
    assert_nil result["desktop_linux"]
  end

  test "serializes computed access_path field" do
    ql = quick_links(:basic_quick_link)
    result = QuickLinkSerializer.serialize(ql)

    assert_equal ql.access_path, result["access_path"]
    assert_equal "https://example.sqd.link/quick-test", result["access_path"]
  end

  test "serializes computed image field from image_resource method" do
    ql = quick_links(:basic_quick_link)
    result = QuickLinkSerializer.serialize(ql)

    # No image attached and no image_url in fixture, so image_resource is nil
    assert_nil result["image"]
  end

  test "serializes no_url_quick_link with its own values" do
    ql = quick_links(:no_url_quick_link)
    result = QuickLinkSerializer.serialize(ql)

    assert_equal "quick-empty", result["path"]
    assert_equal "Empty Quick Link", result["title"]
    assert_equal "No URLs", result["subtitle"]
    assert_nil result["ios_phone"]
    assert_nil result["ios_tablet"]
    assert_nil result["android_phone"]
    assert_nil result["android_tablet"]
    assert_nil result["desktop"]
    assert_nil result["desktop_mac"]
    assert_nil result["desktop_windows"]
    assert_nil result["desktop_linux"]
    assert_equal ql.access_path, result["access_path"]
    assert_equal "https://other.sqd.link/quick-empty", result["access_path"]
  end

  # ---------------------------------------------------------------------------
  # 2. EXCLUSION
  # ---------------------------------------------------------------------------

  test "excludes updated_at created_at id domain_id and image_url" do
    result = QuickLinkSerializer.serialize(quick_links(:basic_quick_link))

    %w[updated_at created_at id domain_id image_url].each do |field|
      assert_not_includes result.keys, field
    end
  end

  # ---------------------------------------------------------------------------
  # 3. NIL HANDLING
  # ---------------------------------------------------------------------------

  test "returns nil for nil input" do
    assert_nil QuickLinkSerializer.serialize(nil)
  end

  # ---------------------------------------------------------------------------
  # 4. COLLECTION HANDLING
  # ---------------------------------------------------------------------------

  test "serializes a collection with correct size and distinct values" do
    quick_links_list = [quick_links(:basic_quick_link), quick_links(:no_url_quick_link)]
    results = QuickLinkSerializer.serialize(quick_links_list)

    assert_equal 2, results.size
    assert_equal "quick-test", results[0]["path"]
    assert_equal "quick-empty", results[1]["path"]
    assert_equal "https://example.sqd.link/quick-test", results[0]["access_path"]
    assert_equal "https://other.sqd.link/quick-empty", results[1]["access_path"]
  end

  # ---------------------------------------------------------------------------
  # 5. EDGE CASES -- computed field variations
  # ---------------------------------------------------------------------------

  test "access_path reflects the domain subdomain and path" do
    ql = quick_links(:basic_quick_link)
    domain = domains(:one)
    result = QuickLinkSerializer.serialize(ql)

    expected = "https://#{domain.subdomain}.#{domain.domain}/#{ql.path}"
    assert_equal expected, result["access_path"]
  end

  test "image is nil when quick link has no image attached and no image_url" do
    ql = quick_links(:basic_quick_link)
    result = QuickLinkSerializer.serialize(ql)

    # Fixture has no image_url column value and no attached image
    assert_nil ql.image_resource
    assert_nil result["image"]
  end
end
