require "test_helper"

# Test ConfigHelpers private methods via a test wrapper
class ConfigHelpersTestWrapper
  include WebConfigurationService::ConfigHelpers

  # Expose private methods for testing
  public :add_query_params_to_link, :validate_link, :appstore_link_for,
         :google_play_link, :uri_valid?, :build_configuration,
         :map_redirect_to_configuration
end

class ConfigHelpersTest < ActiveSupport::TestCase
  fixtures :instances, :projects, :links, :domains, :redirect_configs

  setup do
    @helper = ConfigHelpersTestWrapper.new
    @link = links(:basic_link)
  end

  # --- add_query_params_to_link ---

  test "adds UTM params from link" do
    url = @helper.add_query_params_to_link("https://example.com/page", @link)
    assert_includes url, "utm_campaign=spring2026"
    assert_includes url, "utm_source=email"
    assert_includes url, "utm_medium=newsletter"
  end

  test "preserves existing query params alongside UTM" do
    url = @helper.add_query_params_to_link("https://example.com/page?foo=bar", @link)
    assert_includes url, "foo=bar"
    assert_includes url, "utm_campaign=spring2026"
  end

  test "returns nil URL unchanged" do
    assert_nil @helper.add_query_params_to_link(nil, @link)
  end

  test "returns empty URL unchanged" do
    assert_equal "", @helper.add_query_params_to_link("", @link)
  end

  test "skips nil tracking params" do
    link = links(:second_link)
    url = @helper.add_query_params_to_link("https://example.com", link)
    assert_not_includes url, "utm_campaign"
    assert_not_includes url, "utm_source"
    assert_not_includes url, "utm_medium"
  end

  test "returns URL unchanged when URI is invalid" do
    result = @helper.add_query_params_to_link("not a valid uri with spaces", @link)
    assert_equal "not a valid uri with spaces", result
  end

  # --- appstore_link_for ---

  test "builds valid App Store link" do
    assert_equal "https://apps.apple.com/us/app/id123456", @helper.appstore_link_for("123456")
  end

  test "returns nil for nil app_id" do
    assert_nil @helper.appstore_link_for(nil)
  end

  test "returns nil for empty app_id" do
    assert_nil @helper.appstore_link_for("")
  end

  # --- google_play_link ---

  test "builds valid Play Store link" do
    assert_equal "https://play.google.com/store/apps/details?id=com.example.app",
                 @helper.google_play_link("com.example.app")
  end

  test "returns nil for nil identifier" do
    assert_nil @helper.google_play_link(nil)
  end

  # --- uri_valid? ---

  test "returns true for valid URI" do
    assert @helper.uri_valid?("https://example.com/path?q=1")
  end

  test "returns false for invalid URI with spaces" do
    assert_not @helper.uri_valid?("https://example .com/bad path")
  end

  test "returns true for simple path URI" do
    assert @helper.uri_valid?("/just/a/path")
  end

  # --- validate_link ---

  test "returns true for link with redirect_config and project" do
    assert @helper.validate_link(@link)
  end

  test "returns nil when link has no redirect_config" do
    link_without_rc = Link.new(title: "No RC")
    result = @helper.validate_link(link_without_rc)
    assert_nil result
  end

  # --- build_configuration ---

  test "builds config hash with all fields" do
    config = @helper.build_configuration("Title", "image.png", "appstore://link",
                                          "deeplink://path", "https://fallback.com",
                                          true, false, true)

    assert_equal "Title", config["title"]
    assert_equal "image.png", config["image"]
    assert_equal "deeplink://path", config["deeplink"]
    assert_equal "appstore://link", config["appstore"]
    assert_equal "https://fallback.com", config["fallback"]
    assert_equal true, config["has_app_installed"]
    assert_equal false, config["open_app_if_installed"]
    assert_equal true, config["show_preview"]
  end

  test "build_configuration handles nil values" do
    config = @helper.build_configuration(nil, nil, nil, nil, nil, false, nil, false)
    assert_nil config["title"]
    assert_nil config["deeplink"]
    assert_nil config["appstore"]
    assert_equal false, config["has_app_installed"]
  end

  # --- map_redirect_to_configuration ---

  test "returns config with deeplink and fallback when redirect is enabled" do
    redirect = OpenStruct.new(enabled: true, fallback_url: "https://custom-fallback.com", appstore: false)

    config = @helper.map_redirect_to_configuration(
      "My App", "logo.png", "https://apps.apple.com/id123",
      "myapp://deep/path", redirect, "https://default-fallback.com",
      nil, nil, false, redirect_configs(:one), @link
    )

    assert_equal "My App", config["title"]
    assert_equal "myapp://deep/path", config["deeplink"]
    assert_equal "logo.png", config["image"]
    # Should use custom fallback from redirect, not default
    assert_includes config["fallback"], "custom-fallback.com"
    assert_equal false, config["has_app_installed"]
  end

  test "nullifies deeplink when redirect is disabled" do
    redirect = OpenStruct.new(enabled: false, fallback_url: nil, appstore: false)

    config = @helper.map_redirect_to_configuration(
      "App", "img.png", nil, "myapp://path", redirect, "https://default.com",
      nil, nil, false, redirect_configs(:one), @link
    )

    assert_nil config["deeplink"], "Deeplink should be nil when redirect disabled"
  end

  test "nullifies deeplink when redirect is nil" do
    config = @helper.map_redirect_to_configuration(
      "App", "img.png", nil, "myapp://path", nil, "https://default.com",
      nil, nil, false, redirect_configs(:one), @link
    )

    assert_nil config["deeplink"]
  end

  test "uses appstore link when redirect.appstore is true and link present" do
    redirect = OpenStruct.new(enabled: true, fallback_url: nil, appstore: true)

    config = @helper.map_redirect_to_configuration(
      "App", "img.png", "https://apps.apple.com/id999",
      "myapp://path", redirect, "https://default.com",
      nil, nil, false, redirect_configs(:one), @link
    )

    assert_equal "https://apps.apple.com/id999", config["appstore"]
  end

  test "falls back to default when redirect.appstore is true but appstore_link is blank" do
    redirect = OpenStruct.new(enabled: true, fallback_url: nil, appstore: true)

    config = @helper.map_redirect_to_configuration(
      "App", "img.png", nil, # no appstore link
      "myapp://path", redirect, "https://default-fallback.com",
      nil, nil, false, redirect_configs(:one), links(:second_link) # no tracking params
    )

    assert_nil config["appstore"]
    assert_equal "https://default-fallback.com", config["fallback"]
  end

  test "appends UTM params to fallback URL" do
    redirect = OpenStruct.new(enabled: true, fallback_url: "https://landing.com", appstore: false)

    config = @helper.map_redirect_to_configuration(
      "App", "img.png", nil, "myapp://path", redirect, "https://default.com",
      nil, nil, false, redirect_configs(:one), @link
    )

    assert_includes config["fallback"], "utm_campaign=spring2026"
    assert_includes config["fallback"], "utm_source=email"
  end
end
