require "test_helper"

class InAppBrowserPageTest < ActiveSupport::TestCase
  fixtures :instances, :projects, :domains, :links, :redirect_configs, :redirects,
           :applications, :android_configurations, :custom_redirects

  IPHONE = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 Instagram 342.0.4.27.88"
  IPAD = "Mozilla/5.0 (iPad; CPU OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 Instagram 342.0.4.27.88"
  ANDROID_PHONE = "Mozilla/5.0 (Linux; Android 14; Pixel 8; wv) AppleWebKit/537.36 (KHTML, like Gecko) " \
                  "Version/4.0 Chrome/127.0.0.0 Mobile Safari/537.36 Instagram 343.0.0.33.101 Android"
  ANDROID_TABLET = "Mozilla/5.0 (Linux; Android 14; SM-X910; wv) AppleWebKit/537.36 (KHTML, like Gecko) " \
                   "Version/4.0 Chrome/127.0.0.0 Safari/537.36 Instagram 343.0.0.33.101 Android"

  setup do
    @link = links(:no_custom_redirect_link)
    @config = @link.redirect_config
    @config.update_columns(in_app_browser_page_ios: true, in_app_browser_page_android: true)
  end

  def eligible?(platform, user_agent)
    InAppBrowserPage.eligible?(link: @link.reload, platform: platform, user_agent: user_agent)
  end

  test "eligible on iOS and Android phones when the setting is on and the phone redirect opens the app" do
    assert eligible?(Grovs::Platforms::IOS, IPHONE)
    assert eligible?(Grovs::Platforms::ANDROID, ANDROID_PHONE)
  end

  test "not eligible when the platform setting is off" do
    @config.update_columns(in_app_browser_page_ios: false)
    assert_not eligible?(Grovs::Platforms::IOS, IPHONE)
    assert eligible?(Grovs::Platforms::ANDROID, ANDROID_PHONE)
  end

  test "not eligible on desktop, web, mac or windows" do
    [Grovs::Platforms::DESKTOP, Grovs::Platforms::WEB, Grovs::Platforms::MAC, Grovs::Platforms::WINDOWS].each do |p|
      assert_not eligible?(p, IPHONE), p
    end
  end

  test "not eligible when the phone redirect is web-only" do
    @config.ios_phone_redirect.update_columns(enabled: false)
    assert_not eligible?(Grovs::Platforms::IOS, IPHONE)
  end

  test "not eligible when no phone redirect exists" do
    @config.android_phone_redirect.destroy
    assert_not eligible?(Grovs::Platforms::ANDROID, ANDROID_PHONE)
  end

  test "per-link custom redirect decides: open_app_if_installed false is not eligible" do
    CustomRedirect.create!(link: @link, platform: Grovs::Platforms::IOS, url: "https://example.com/web", open_app_if_installed: false)
    assert_not eligible?(Grovs::Platforms::IOS, IPHONE)
  end

  test "per-link custom redirect with open_app_if_installed true is eligible even when the phone redirect is web-only" do
    @config.ios_phone_redirect.update_columns(enabled: false)
    CustomRedirect.create!(link: @link, platform: Grovs::Platforms::IOS, url: "https://example.com/web", open_app_if_installed: true)
    assert eligible?(Grovs::Platforms::IOS, IPHONE)
  end

  def tablet_redirect!(platform, enabled:)
    app = platform == "ios" ? applications(:ios_app) : applications(:android_app)
    Redirect.create!(redirect_config: @config, application: app, platform: platform, variation: "tablet",
                     enabled: enabled, appstore: false, fallback_url: "https://example.com/tablet")
  end

  test "tablet with a disabled tablet redirect is not eligible; phone is unaffected" do
    tablet_redirect!("ios", enabled: false)
    assert_not eligible?(Grovs::Platforms::IOS, IPAD)
    assert eligible?(Grovs::Platforms::IOS, IPHONE)
  end

  test "tablet with no tablet redirect falls back to the phone redirect" do
    assert eligible?(Grovs::Platforms::ANDROID, ANDROID_TABLET)
    @config.android_phone_redirect.update_columns(enabled: false)
    assert_not eligible?(Grovs::Platforms::ANDROID, ANDROID_TABLET)
  end

  test "tablet with its own tablet redirect is not eligible, even when enabled" do
    @config.ios_phone_redirect.update_columns(enabled: false)
    tablet_redirect!("ios", enabled: true)
    assert_not eligible?(Grovs::Platforms::IOS, IPAD)
    assert_not eligible?(Grovs::Platforms::IOS, IPHONE)
  end

  test "custom redirect that opens the app beats a tablet's own enabled redirect" do
    tablet_redirect!("ios", enabled: true)
    CustomRedirect.create!(link: @link, platform: Grovs::Platforms::IOS, url: "https://example.com/web", open_app_if_installed: true)
    assert eligible?(Grovs::Platforms::IOS, IPAD)
  end

  test "missing redirect_config is not eligible and does not raise" do
    @link.stub(:redirect_config, nil) do
      assert_not InAppBrowserPage.eligible?(link: @link, platform: Grovs::Platforms::IOS, user_agent: IPHONE)
    end
  end

  # --- button_url ---

  def fallback_url
    "#{@link.access_path}?go_to_fallback=true"
  end

  test "iOS button is unchanged" do
    assert_equal fallback_url, InAppBrowserPage.button_url(redirect_url: fallback_url, link: @link, platform: Grovs::Platforms::IOS, in_app_browser: true)
  end

  test "Android button is unchanged outside an in-app browser" do
    assert_equal fallback_url, InAppBrowserPage.button_url(redirect_url: fallback_url, link: @link, platform: Grovs::Platforms::ANDROID, in_app_browser: false)
  end

  test "Android in-app browser button is an https App Link intent with the same URL as fallback" do
    url = InAppBrowserPage.button_url(redirect_url: fallback_url, link: @link, platform: Grovs::Platforms::ANDROID, in_app_browser: true)
    host_path = fallback_url.delete_prefix("https://")

    assert_equal "intent://#{host_path}#Intent;scheme=https;package=com.test.androidapp;" \
                 "S.browser_fallback_url=#{CGI.escape(fallback_url)};end", url
  end

  test "Android keeps a gd query param inside the intent" do
    with_gd = "#{@link.access_path}?gd=abc&go_to_fallback=true"
    url = InAppBrowserPage.button_url(redirect_url: with_gd, link: @link, platform: Grovs::Platforms::ANDROID, in_app_browser: true)
    assert url.start_with?("intent://#{with_gd.delete_prefix('https://')}#Intent;")
  end

  test "Android without an Android app configuration keeps the https button" do
    InAppBrowserPage.stub(:android_package, nil) do
      assert_equal fallback_url, InAppBrowserPage.button_url(redirect_url: fallback_url, link: @link, platform: Grovs::Platforms::ANDROID, in_app_browser: true)
    end
  end

  test "Android direct custom-redirect URL is not wrapped" do
    direct = "https://shop.example.com/sale?utm_campaign=x"
    assert_equal direct, InAppBrowserPage.button_url(redirect_url: direct, link: @link, platform: Grovs::Platforms::ANDROID, in_app_browser: true)
  end

  test "unparseable redirect url is returned untouched" do
    assert_equal "not a url", InAppBrowserPage.button_url(redirect_url: "not a url", link: @link, platform: Grovs::Platforms::ANDROID, in_app_browser: true)
  end

  # --- hint_text ---

  test "hint text uses the platform's menu glyph" do
    assert_equal "Not opening? Tap ⋯ and choose Open in browser.", InAppBrowserPage.hint_text(Grovs::Platforms::IOS)
    assert_equal "Not opening? Tap ⋮ and choose Open in browser.", InAppBrowserPage.hint_text(Grovs::Platforms::ANDROID)
  end
end
