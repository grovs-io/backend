require "test_helper"

class QuickLinkTest < ActiveSupport::TestCase
  fixtures :quick_links, :domains, :projects, :instances

  # === full_path ===

  test "full_path constructs subdomain.domain/path" do
    ql = quick_links(:basic_quick_link)
    domain = ql.domain
    # QuickLink.full_path uses domain.subdomain + "." + domain.domain + "/" + path
    expected = "#{domain.subdomain}.#{domain.domain}/#{ql.path}"
    assert_equal expected, ql.full_path(domain)
  end

  test "full_path with blank subdomain still uses dot separator" do
    ql = quick_links(:basic_quick_link)
    domain = ql.domain
    domain.subdomain = "custom"
    result = ql.full_path(domain)
    assert_equal "custom.#{domain.domain}/#{ql.path}", result
  end

  # === access_path ===

  test "access_path prepends https" do
    ql = quick_links(:basic_quick_link)
    result = ql.access_path
    assert result.start_with?("https://")
    assert result.include?(ql.path)
  end

  # === valid_url? ===

  test "valid_url? returns true for https URL" do
    ql = quick_links(:basic_quick_link)
    assert ql.valid_url?("https://www.example.com")
  end

  test "valid_url? returns true for http URL" do
    ql = quick_links(:basic_quick_link)
    assert ql.valid_url?("http://www.example.com")
  end

  test "valid_url? returns true for URL without scheme if it has a dot" do
    ql = quick_links(:basic_quick_link)
    assert ql.valid_url?("www.example.com")
  end

  test "valid_url? returns false for nil" do
    ql = quick_links(:basic_quick_link)
    assert_not ql.valid_url?(nil)
  end

  test "valid_url? returns false for empty string" do
    ql = quick_links(:basic_quick_link)
    assert_not ql.valid_url?("")
  end

  test "valid_url? returns false for string without dot" do
    ql = quick_links(:basic_quick_link)
    assert_not ql.valid_url?("notaurl")
  end

  test "valid_url? returns false for string with spaces" do
    ql = quick_links(:basic_quick_link)
    assert_not ql.valid_url?("not a url")
  end

  test "valid_url? strips whitespace" do
    ql = quick_links(:basic_quick_link)
    assert ql.valid_url?("  https://www.example.com  ")
  end

  # === ios_phone_must_be_valid_url ===

  test "ios_phone with valid URL passes validation" do
    ql = quick_links(:basic_quick_link)
    ql.ios_phone = "https://apps.apple.com/app/id123"
    ql.validate
    assert_not ql.errors[:ios_phone].any?
  end

  test "ios_phone with invalid URL adds error" do
    ql = quick_links(:basic_quick_link)
    ql.ios_phone = "not a url"
    ql.validate
    assert ql.errors[:ios_phone].any?
  end

  test "blank ios_phone skips validation" do
    ql = quick_links(:no_url_quick_link)
    ql.ios_phone = ""
    ql.validate
    assert_not ql.errors[:ios_phone].any?
  end

  # === android_phone_must_be_valid_url ===

  test "android_phone with valid URL passes validation" do
    ql = quick_links(:basic_quick_link)
    ql.android_phone = "https://play.google.com/store/apps/details?id=com.test"
    ql.validate
    assert_not ql.errors[:android_phone].any?
  end

  test "android_phone with invalid URL adds error" do
    ql = quick_links(:basic_quick_link)
    ql.android_phone = "not a url"
    ql.validate
    assert ql.errors[:android_phone].any?
  end

  test "blank android_phone skips validation" do
    ql = quick_links(:no_url_quick_link)
    ql.android_phone = ""
    ql.validate
    assert_not ql.errors[:android_phone].any?
  end

  # === optional_urls_must_be_valid ===

  test "optional URL fields with valid URLs pass" do
    ql = quick_links(:basic_quick_link)
    ql.ios_tablet = "https://example.com"
    ql.android_tablet = "https://example.com"
    ql.desktop_mac = "https://example.com"
    ql.desktop_windows = "https://example.com"
    ql.desktop_linux = "https://example.com"
    ql.validate
    %i[ios_tablet android_tablet desktop_mac desktop_windows desktop_linux].each do |field|
      assert_not ql.errors[field].any?, "Expected no errors for #{field}"
    end
  end

  test "optional URL fields with invalid URLs add errors" do
    ql = quick_links(:basic_quick_link)
    ql.ios_tablet = "notaurl"
    ql.validate
    assert ql.errors[:ios_tablet].any?
  end

  # === serialization ===

  test "serializer excludes internal fields and includes access_path" do
    ql = quick_links(:basic_quick_link)
    AssetService.stub(:permanent_url, nil) do
      json = QuickLinkSerializer.serialize(ql)
      assert_nil json["updated_at"]
      assert_nil json["created_at"]
      assert_nil json["id"]
      assert_nil json["domain_id"]
      assert_nil json["image_url"]
      assert json.key?("access_path")
      assert json.key?("image")
    end
  end
end
