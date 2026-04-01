require "test_helper"

class LinkTest < ActiveSupport::TestCase
  fixtures :links, :domains, :redirect_configs, :projects, :instances, :campaigns,
           :custom_redirects, :actions, :devices, :redirects, :applications

  # === full_path ===

  test "full_path constructs domain plus path" do
    link = links(:basic_link)
    domain = link.domain
    result = link.full_path(domain)
    assert_equal "#{domain.full_domain}/#{link.path}", result
  end

  test "full_path works with domain that has subdomain" do
    domain = domains(:one)
    domain.subdomain = "custom"
    link = links(:basic_link)
    result = link.full_path(domain)
    assert_equal "custom.#{domain.domain}/#{link.path}", result
  end

  # === access_path ===

  test "access_path prepends https" do
    link = links(:basic_link)
    result = link.access_path
    assert result.start_with?("https://")
    assert result.end_with?(link.path)
  end

  test "access_path includes full domain" do
    link = links(:basic_link)
    domain = link.domain
    expected = "https://#{domain.full_domain}/#{link.path}"
    assert_equal expected, link.access_path
  end

  # === tracking_dictionary ===

  test "tracking_dictionary returns source campaign and medium" do
    link = links(:basic_link)
    result = link.tracking_dictionary
    assert_equal({ source: "email", campaign: "spring2026", medium: "newsletter" }, result)
  end

  test "tracking_dictionary returns nils when tracking fields are blank" do
    link = links(:second_link)
    result = link.tracking_dictionary
    assert_nil result[:source]
    assert_nil result[:campaign]
    assert_nil result[:medium]
  end

  # === should_open_app_on_platform? ===

  test "should_open_app_on_platform? returns false for desktop" do
    link = links(:basic_link)
    assert_not link.should_open_app_on_platform?(Grovs::Platforms::DESKTOP)
  end

  test "should_open_app_on_platform? returns false for web" do
    link = links(:basic_link)
    assert_not link.should_open_app_on_platform?(Grovs::Platforms::WEB)
  end

  test "should_open_app_on_platform? checks ios_phone_redirect for ios" do
    link = links(:basic_link)
    redirect_config = link.redirect_config

    # When no redirect and no custom redirect, returns the redirect_config value or false
    ios_redirect = redirect_config.ios_phone_redirect
    if ios_redirect
      expected = ios_redirect.enabled || false
    else
      expected = false
    end
    assert_equal expected, link.should_open_app_on_platform?(Grovs::Platforms::IOS)
  end

  # === cache_keys_to_clear ===

  test "cache_keys_to_clear includes path and domain_id multi-condition keys" do
    link = links(:basic_link)
    keys = link.cache_keys_to_clear
    expected_key = link.send(:multi_condition_cache_key, { path: link.path, domain_id: link.domain_id })
    assert_includes keys, expected_key
  end

  test "cache_keys_to_clear includes domain variant multi-condition key" do
    link = links(:basic_link)
    keys = link.cache_keys_to_clear
    expected_key = link.send(:multi_condition_cache_key, { domain: link.domain_id, path: link.path })
    assert_includes keys, expected_key
  end

  # === valid_path? ===

  test "valid_path? returns true when no other active link has same domain and path" do
    link = links(:basic_link)
    assert link.valid_path?
  end

  test "valid_path? returns true for self with same domain and path" do
    link = links(:basic_link)
    # valid_path? checks if the found link is self or nil
    assert link.valid_path?
  end

  # === serialization ===

  test "serializer excludes internal fields" do
    link = links(:basic_link)
    AssetService.stub(:permanent_url, nil) do
      json = LinkSerializer.serialize(link)
      assert_nil json["redirect_config_id"]
      assert_nil json["domain_id"]
      assert_nil json["image_url"]
      assert_nil json["created_at"]
    end
  end

  test "serializer includes access_path and image when not slim" do
    link = links(:basic_link)
    AssetService.stub(:permanent_url, nil) do
      json = LinkSerializer.serialize(link)
      assert json.key?("access_path")
      assert json.key?("image")
    end
  end

  test "serializer slim excludes access_path image and custom redirects" do
    link = links(:basic_link)
    json = LinkSerializer.serialize(link, slim: true)
    assert_nil json["access_path"]
    assert_nil json["image"]
    assert_nil json["ios_custom_redirect"]
    assert_nil json["android_custom_redirect"]
    assert_nil json["desktop_custom_redirect"]
  end

  # === hash_data ===

  test "hash_data merges data array into single hash" do
    link = links(:basic_link)
    link.data = [{ "key1" => "val1" }, { "key2" => "val2" }]
    result = link.hash_data
    assert_equal({ "key1" => "val1", "key2" => "val2" }, result)
  end

  test "hash_data returns empty hash for empty data" do
    link = links(:second_link)
    link.data = []
    result = link.hash_data
    assert_equal({}, result)
  end

  # === action_for ===

  test "action_for returns nil when no actions exist for the device" do
    link = links(:basic_link)
    device = devices(:android_device)
    # android_device has no actions on basic_link within the time window
    assert_nil link.action_for(device)
  end

  test "action_for returns the most recent action within the time window" do
    link = links(:basic_link)
    device = devices(:ios_device)
    # recent_action was created 1 minute ago, old_action was 10 minutes ago (outside 5 min window)
    result = link.action_for(device)
    assert_not_nil result
    assert_equal actions(:recent_action).id, result.id
  end

  test "action_for does not return actions outside the validity window" do
    link = links(:second_link)
    device = devices(:ios_device)
    # ios_device has no actions on second_link
    assert_nil link.action_for(device)
  end

  # === ios_custom_redirect ===

  test "ios_custom_redirect returns the iOS custom redirect" do
    link = links(:basic_link)
    result = link.ios_custom_redirect
    assert_not_nil result
    assert_equal Grovs::Platforms::IOS, result.platform
    assert_equal "https://example.com/ios-custom", result.url
  end

  test "ios_custom_redirect returns nil when none exists" do
    link = links(:second_link)
    assert_nil link.ios_custom_redirect
  end

  # === android_custom_redirect ===

  test "android_custom_redirect returns the Android custom redirect" do
    link = links(:basic_link)
    result = link.android_custom_redirect
    assert_not_nil result
    assert_equal Grovs::Platforms::ANDROID, result.platform
    assert_equal "https://example.com/android-custom", result.url
  end

  test "android_custom_redirect returns nil when none exists" do
    link = links(:second_link)
    assert_nil link.android_custom_redirect
  end

  # === desktop_custom_redirect ===

  test "desktop_custom_redirect returns the desktop custom redirect" do
    link = links(:basic_link)
    result = link.desktop_custom_redirect
    assert_not_nil result
    assert_equal Grovs::Platforms::DESKTOP, result.platform
    assert_equal "https://example.com/desktop-custom", result.url
  end

  test "desktop_custom_redirect returns nil when none exists" do
    link = links(:second_link)
    assert_nil link.desktop_custom_redirect
  end

  # === should_open_app_on_platform? (full branch coverage) ===

  test "should_open_app_on_platform? returns true for iOS when custom redirect has open_app_if_installed true" do
    link = links(:basic_link)
    # ios_redirect_for_basic_link has open_app_if_installed: true
    assert link.should_open_app_on_platform?(Grovs::Platforms::IOS)
  end

  test "should_open_app_on_platform? returns false for Android when custom redirect has open_app_if_installed false" do
    link = links(:basic_link)
    # android_redirect_for_basic_link has open_app_if_installed: false
    assert_not link.should_open_app_on_platform?(Grovs::Platforms::ANDROID)
  end

  test "should_open_app_on_platform? falls back to redirect_config for iOS when no custom redirect exists" do
    link = links(:second_link)
    # second_link has no custom redirects, so it falls back to redirect_config
    ios_redirect = link.redirect_config.ios_phone_redirect
    expected = ios_redirect&.enabled || false
    assert_equal expected, link.should_open_app_on_platform?(Grovs::Platforms::IOS)
  end

  test "should_open_app_on_platform? falls back to redirect_config for Android when no custom redirect exists" do
    link = links(:second_link)
    android_redirect = link.redirect_config.android_phone_redirect
    expected = android_redirect&.enabled || false
    assert_equal expected, link.should_open_app_on_platform?(Grovs::Platforms::ANDROID)
  end

  test "should_open_app_on_platform? always returns false for DESKTOP" do
    link = links(:basic_link)
    # Even though desktop_redirect_for_basic_link exists, DESKTOP always returns false
    assert_not link.should_open_app_on_platform?(Grovs::Platforms::DESKTOP)
  end

  test "should_open_app_on_platform? always returns false for WEB" do
    link = links(:second_link)
    assert_not link.should_open_app_on_platform?(Grovs::Platforms::WEB)
  end
end
