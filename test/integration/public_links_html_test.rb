require "test_helper"
require "nokogiri"

class PublicLinksHtmlTest < ActionDispatch::IntegrationTest
  fixtures :instances, :projects, :domains, :links, :redirect_configs, :redirects,
           :applications, :ios_configurations, :android_configurations,
           :desktop_configurations

  APPSTORE_STUB = { title: "Test iOS App", image: "https://cdn.example.com/ios-icon.png", appstore_id: "123456" }
  GOOGLE_PLAY_STUB = { title: "Test Android App", image: "https://cdn.example.com/android-icon.png" }

  setup do
    @project = projects(:one)
    @domain = domains(:one)
    @link = links(:no_custom_redirect_link)
    @instance = instances(:one)
  end

  # --- 1. iOS template with correct embedded JSON config ---

  test "iOS template renders correct embedded JSON config with phone and tablet" do
    stub_external_stores do
      get "/#{@link.path}", headers: public_host_headers, env: { "HTTP_USER_AGENT" => iphone_ua }
      assert_response :ok

      doc = Nokogiri::HTML(response.body)
      popup = doc.at_css("#popup")
      assert popup, "Expected #popup element in response"

      ios_json = JSON.parse(popup["ios"])

      # Phone config
      phone = ios_json["phone"]
      assert_equal "testapp://standard-path", phone["deeplink"]
      assert_includes phone["appstore"], "apps.apple.com/us/app/id123456"
      assert_includes phone["appstore"], "ct=spring2026"
      assert_includes phone["appstore"], "at=email"
      assert_includes phone["appstore"], "pt=newsletter"
      assert_match %r{https://example\.com/fallback\?}, phone["fallback"]
      assert_includes phone["fallback"], "utm_campaign=spring2026"
      assert_includes phone["fallback"], "utm_source=email"
      assert_includes phone["fallback"], "utm_medium=newsletter"
      assert_includes [true, false], phone["has_app_installed"], "has_app_installed should be a boolean"
      assert_equal false, phone["show_preview"]
      assert_equal "Test iOS App", phone["title"]

      # Tablet config — no tablet redirect fixture, so tablet inherits phone config
      tablet = ios_json["tablet"]
      assert tablet, "Expected tablet config in iOS JSON"
      assert_equal phone["deeplink"], tablet["deeplink"]
      assert_equal phone["appstore"], tablet["appstore"]
      assert_equal phone["fallback"], tablet["fallback"]
    end
  end

  test "has_app_installed is true when InstalledApp record exists for device" do
    stub_external_stores do
      # First visit: creates/finds device
      get "/#{@link.path}", headers: public_host_headers, env: { "HTTP_USER_AGENT" => iphone_ua }
      assert_response :ok

      device = Device.fetch_by_hash_id(cookies["LINKSQUARED"])
      assert device

      # Clear any stale Redis cache for this device+project combo left by
      # previous test runs (fixture transactions roll back DB rows but Redis
      # cache entries persist).
      stale = InstalledApp.new(device_id: device.id, project_id: @project.id)
      stale.cache_keys_to_clear.each { |key| REDIS.with { |c| c.del(key) } }

      # Ensure no InstalledApp exists in DB either
      InstalledApp.where(device_id: device.id, project_id: @project.id).delete_all

      # Visit again with clean state: has_app_installed should be false
      get "/#{@link.path}", headers: public_host_headers, env: { "HTTP_USER_AGENT" => iphone_ua }
      assert_response :ok

      ios_json = JSON.parse(Nokogiri::HTML(response.body).at_css("#popup")["ios"])
      assert_equal false, ios_json["phone"]["has_app_installed"]

      # Create InstalledApp for this device + project
      InstalledApp.create!(device: device, project: @project)

      # Third visit: same device (via cookie), now has_app_installed should be true
      get "/#{@link.path}", headers: public_host_headers, env: { "HTTP_USER_AGENT" => iphone_ua }
      assert_response :ok

      ios_json = JSON.parse(Nokogiri::HTML(response.body).at_css("#popup")["ios"])
      assert_equal true, ios_json["phone"]["has_app_installed"]
    end
  end

  # --- 2. Android template with correct embedded JSON config ---

  test "Android template renders correct embedded JSON config with phone and tablet" do
    stub_external_stores do
      get "/#{@link.path}", headers: public_host_headers, env: { "HTTP_USER_AGENT" => android_ua }
      assert_response :ok

      doc = Nokogiri::HTML(response.body)
      popup = doc.at_css("#popup")
      assert popup, "Expected #popup element in response"

      android_json = JSON.parse(popup["android"])

      # Phone config
      phone = android_json["phone"]
      assert_equal "testapp://standard-path", phone["deeplink"]
      assert_nil phone["appstore"], "Android redirect has appstore: false, so appstore link should be nil"
      assert_match %r{https://example\.com/fallback\?}, phone["fallback"]
      assert_includes phone["fallback"], "utm_campaign=spring2026"
      assert_includes phone["fallback"], "utm_source=email"
      assert_includes phone["fallback"], "utm_medium=newsletter"
      assert_equal "Test Android App", phone["title"]

      # Tablet config — no tablet redirect fixture, so tablet inherits phone config
      tablet = android_json["tablet"]
      assert tablet, "Expected tablet config in Android JSON"
      assert_equal phone["deeplink"], tablet["deeplink"]
      assert_equal phone["fallback"], tablet["fallback"]
    end
  end

  # --- 3. Desktop template with correct embedded JSON config ---

  test "Desktop template renders correct embedded JSON config" do
    stub_external_stores do
      get "/#{@link.path}", headers: public_host_headers, env: { "HTTP_USER_AGENT" => desktop_ua }
      assert_response :ok

      doc = Nokogiri::HTML(response.body)
      desktop_view = doc.at_css("#desktop-view")
      assert desktop_view, "Expected #desktop-view element in response"

      desktop_json = JSON.parse(desktop_view["desktop"])

      # Desktop config has explicit fallback_url, so generated page (linksquared key) is nil
      assert_nil desktop_json["linksquared"]

      # Mac config comes from desktop_redirect fixture (fallback_url: "https://example.com/desktop-fallback")
      mac = desktop_json["mac"]
      assert mac, "Expected mac config in desktop JSON"
      assert_nil mac["deeplink"]
      assert_nil mac["appstore"]
      assert_equal "https://example.com/desktop-fallback", mac["fallback"]
      assert_equal "Test iOS App", mac["title"]

      # Windows config mirrors mac
      windows = desktop_json["windows"]
      assert windows, "Expected windows config in desktop JSON"
      assert_equal mac["fallback"], windows["fallback"]

      # Top-level fallback comes from DesktopConfiguration fixture (fallback_url: "https://example.com/desktop")
      assert_equal "https://example.com/desktop", desktop_json["fallback"]
    end
  end

  # --- 4. OG meta tags match link fixture data ---

  test "OG meta tags match link fixture data" do
    stub_external_stores do
      get "/#{@link.path}", headers: public_host_headers, env: { "HTTP_USER_AGENT" => iphone_ua }
      assert_response :ok

      doc = Nokogiri::HTML(response.body)

      assert_equal "Standard Link", doc.at("meta[property='og:title']")["content"]
      assert_equal "A standard link without custom redirects", doc.at("meta[property='og:description']")["content"]
      assert_includes doc.at("meta[property='og:url']")["content"], "example.sqd.link/standard-path"

      # og:image falls through to domain.generic_image_url since link has no image
      assert_equal "https://cdn.example.com/og-image.jpg", doc.at("meta[property='og:image']")["content"]

      # Twitter meta tags mirror OG
      assert_equal "Standard Link", doc.at("meta[name='twitter:title']")["content"]
      assert_equal "A standard link without custom redirects", doc.at("meta[name='twitter:description']")["content"]
      assert_equal "https://cdn.example.com/og-image.jpg", doc.at("meta[name='twitter:image']")["content"]
    end
  end

  # --- 5. Platform-specific JS file included per User-Agent ---

  test "iOS response includes handle_ios script but not other platforms" do
    stub_external_stores do
      get "/#{@link.path}", headers: public_host_headers, env: { "HTTP_USER_AGENT" => iphone_ua }
      assert_response :ok

      assert_includes response.body, "handle_ios"
      assert_includes response.body, "handleiOSIfNeeded()"
      assert_not_includes response.body, "handle_android"
      assert_not_includes response.body, "handle_desktop"
      assert_common_scripts
    end
  end

  test "Android response includes handle_android script but not other platforms" do
    stub_external_stores do
      get "/#{@link.path}", headers: public_host_headers, env: { "HTTP_USER_AGENT" => android_ua }
      assert_response :ok

      assert_includes response.body, "handle_android"
      assert_includes response.body, "handleAndroidIfNeeded()"
      assert_not_includes response.body, "handle_ios"
      assert_not_includes response.body, "handle_desktop"
      assert_common_scripts
    end
  end

  test "Desktop response includes handle_desktop script but not other platforms" do
    stub_external_stores do
      get "/#{@link.path}", headers: public_host_headers, env: { "HTTP_USER_AGENT" => desktop_ua }
      assert_response :ok

      assert_includes response.body, "handle_desktop"
      assert_includes response.body, "handleDesktop()"
      assert_not_includes response.body, "handle_ios"
      assert_not_includes response.body, "handle_android"
      assert_common_scripts
    end
  end

  # --- 6. LINKSQUARED cookie set on first visit ---

  test "LINKSQUARED cookie is set on first visit and maps to a Device" do
    stub_external_stores do
      get "/#{@link.path}", headers: public_host_headers, env: { "HTTP_USER_AGENT" => iphone_ua }
      assert_response :ok

      cookie_value = cookies["LINKSQUARED"]
      assert cookie_value.present?, "Expected LINKSQUARED cookie to be set"

      device = Device.fetch_by_hash_id(cookie_value)
      assert device, "Expected a Device record for the cookie hashid"
      assert_equal "ios", device.platform
    end
  end

  # --- 7. Cache-Control headers ---

  test "Cache-Control and Pragma no-cache headers are set" do
    stub_external_stores do
      get "/#{@link.path}", headers: public_host_headers, env: { "HTTP_USER_AGENT" => iphone_ua }
      assert_response :ok

      assert_includes response.headers["Cache-Control"], "no-store"
      assert_equal "no-cache", response.headers["Pragma"]
      assert_equal "Mon, 01 Jan 1990 00:00:00 GMT", response.headers["Expires"]
    end
  end

  # --- 8. Google Analytics script ---

  test "Google Analytics script included when tracking ID present" do
    stub_external_stores do
      get "/#{@link.path}", headers: public_host_headers, env: { "HTTP_USER_AGENT" => iphone_ua }
      assert_response :ok

      assert_includes response.body, "googletagmanager.com/gtag/js?id=G-TEST12345"
    end
  end

  test "Google Analytics script absent on not-found page" do
    get "/nonexistent-path-xyz", headers: public_host_headers
    assert_response :ok

    assert_not_includes response.body, "googletagmanager.com/gtag/js"
  end

  # --- 9. Not found path renders 404 page without device creation ---

  test "not found path renders void page without LINKSQUARED cookie" do
    device_count_before = Device.count

    get "/nonexistent-path-xyz", headers: public_host_headers
    assert_response :ok

    doc = Nokogiri::HTML(response.body)
    assert_includes response.body, "Lost in the Void"
    assert_nil doc.at_css("#popup"), "Expected no #popup element for not-found page"

    cookie_value = cookies["LINKSQUARED"]
    assert_nil cookie_value, "Expected no LINKSQUARED cookie on not-found page"

    assert_equal device_count_before, Device.count, "Expected no new Device records for not-found"
  end

  # --- 10. store_device_data POST updates Device record ---

  test "store_device_data POST updates Device attributes" do
    stub_external_stores do
      # First visit to create device and get cookie
      get "/#{@link.path}", headers: public_host_headers, env: { "HTTP_USER_AGENT" => iphone_ua }
      assert_response :ok

      cookie_value = cookies["LINKSQUARED"]
      assert cookie_value.present?

      device = Device.fetch_by_hash_id(cookie_value)
      assert device
      assert_nil device.screen_width, "Screen width should be nil before POST"

      # POST device data
      post "/",
           params: { screen_width: 1920, screen_height: 1080, timezone: "America/New_York", language: "en-US" }.to_json,
           headers: public_host_headers.merge("Content-Type" => "application/json"),
           env: { "HTTP_USER_AGENT" => iphone_ua }

      device.reload
      assert_equal 1920, device.screen_width
      assert_equal 1080, device.screen_height
      assert_equal "America/New_York", device.timezone
      assert_equal "en-US", device.language
    end
  end

  private

  def stub_external_stores(&block)
    AppstoreService.stub(:fetch_image_and_title_for_identifier, APPSTORE_STUB) do
      GooglePlayService.stub(:fetch_image_and_title_for_identifier, GOOGLE_PLAY_STUB, &block)
    end
  end

  def public_host_headers
    { "Host" => "#{@domain.subdomain}.#{@domain.domain}" }
  end

  def iphone_ua
    "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
  end

  def android_ua
    "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36"
  end

  def desktop_ua
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
  end

  def assert_common_scripts
    assert_includes response.body, "helpers"
    assert_includes response.body, "configure_view"
    assert_includes response.body, "device_detection"
    assert_includes response.body, "deeplink_process"
  end
end
