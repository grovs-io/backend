require "test_helper"

class WebConfigurationServiceTest < ActiveSupport::TestCase
  fixtures :instances, :projects, :links, :domains, :redirect_configs, :redirects,
           :applications, :ios_configurations, :android_configurations, :desktop_configurations,
           :devices, :visitors, :custom_redirects

  setup do
    @project = projects(:one)
    @instance = instances(:one)
    @link = links(:second_link) # no custom redirects
    @device = devices(:ios_device)

    @ios_store_result = { title: "Test App", image: "https://example.com/icon.png", appstore_id: "123456789" }
    @android_store_result = { title: "Test App", image: "https://example.com/icon.png" }
  end

  def with_store_stubs(&block)
    AppstoreService.stub(:fetch_image_and_title_for_identifier, @ios_store_result) do
      GooglePlayService.stub(:fetch_image_and_title_for_identifier, @android_store_result, &block)
    end
  end

  # --- Custom redirect bypasses appstore/deeplink ---

  test "custom redirect sets fallback to custom URL and nils out deeplink and appstore" do
    link_with_custom = links(:basic_link)

    with_store_stubs do
      result = WebConfigurationService.configuration_for_ios(link_with_custom, @device, @project)

      assert_includes result[:phone]["fallback"], "ios-custom"
      assert_nil result[:phone]["deeplink"]
      assert_nil result[:phone]["appstore"]
    end
  end

  # --- Tablet fallback ---

  test "tablet config equals phone config when phone redirect exists but tablet is nil" do
    AppstoreService.stub(:fetch_image_and_title_for_identifier, @ios_store_result) do
      result = WebConfigurationService.configuration_for_ios(@link, @device, @project)

      assert_equal result[:phone], result[:tablet]
    end
  end

  # --- Fallback image and name ---

  test "uses LOGO when store image is blank" do
    blank_image = { title: "Test App", image: "", appstore_id: "123456789" }

    AppstoreService.stub(:fetch_image_and_title_for_identifier, blank_image) do
      result = WebConfigurationService.configuration_for_ios(@link, @device, @project)

      assert_equal Grovs::Links::LOGO, result[:phone]["image"]
    end
  end

  test "uses project name when store title is blank" do
    blank_title = { title: "", image: "https://example.com/icon.png", appstore_id: "123456789" }

    AppstoreService.stub(:fetch_image_and_title_for_identifier, blank_title) do
      result = WebConfigurationService.configuration_for_ios(@link, @device, @project)

      assert_equal @project.name, result[:phone]["title"]
    end
  end

  # --- PLATFORM_CONFIG lambda unit tests ---

  test "iOS store_link builds correct Apple URL" do
    pc = WebConfigurationService::PLATFORM_CONFIG[:ios]
    assert_equal "https://apps.apple.com/us/app/id999888777", pc[:store_link].call({ appstore_id: "999888777" }, nil)
  end

  test "iOS store_link returns nil for nil appstore_id" do
    pc = WebConfigurationService::PLATFORM_CONFIG[:ios]
    assert_nil pc[:store_link].call({ appstore_id: nil }, nil)
  end

  test "iOS store_link returns nil for empty appstore_id" do
    pc = WebConfigurationService::PLATFORM_CONFIG[:ios]
    assert_nil pc[:store_link].call({ appstore_id: "" }, nil)
  end

  test "Android store_link builds correct Play Store URL" do
    pc = WebConfigurationService::PLATFORM_CONFIG[:android]
    config = OpenStruct.new(identifier: "com.example.app")
    assert_equal "https://play.google.com/store/apps/details?id=com.example.app", pc[:store_link].call({}, config)
  end

  test "iOS tracking_params maps campaign/source/medium to ct/at/pt" do
    pc = WebConfigurationService::PLATFORM_CONFIG[:ios]
    link = OpenStruct.new(tracking_campaign: "camp", tracking_source: "src", tracking_medium: "med")
    assert_equal [['ct', 'camp'], ['at', 'src'], ['pt', 'med']], pc[:tracking_params].call(link)
  end

  test "iOS tracking_params omits nil values" do
    pc = WebConfigurationService::PLATFORM_CONFIG[:ios]
    link = OpenStruct.new(tracking_campaign: "camp", tracking_source: nil, tracking_medium: nil)
    assert_equal [['ct', 'camp']], pc[:tracking_params].call(link)
  end

  test "iOS tracking_params returns empty array when all nil" do
    pc = WebConfigurationService::PLATFORM_CONFIG[:ios]
    link = OpenStruct.new(tracking_campaign: nil, tracking_source: nil, tracking_medium: nil)
    assert_equal [], pc[:tracking_params].call(link)
  end

  test "Android tracking_params includes referrer plus utm params" do
    pc = WebConfigurationService::PLATFORM_CONFIG[:android]
    link = OpenStruct.new(access_path: "https://example.sqd.link/test",
                          tracking_campaign: "camp", tracking_source: "src", tracking_medium: "med")
    assert_equal [
      ['referrer', 'https://example.sqd.link/test'],
      ['utm_campaign', 'camp'], ['utm_source', 'src'], ['utm_medium', 'med']
    ], pc[:tracking_params].call(link)
  end

  test "desktop with explicit fallback_url nils linksquared and exposes the fallback at top level" do
    with_store_stubs do
      result = WebConfigurationService.configure_for_desktop(@link)

      assert_nil result[:linksquared]
      assert_equal "https://example.com/desktop", result[:fallback]
    end
  end

  test "desktop without explicit fallback_url builds the generated page and uses default fallback" do
    desktop_configurations(:one).update!(fallback_url: nil)

    with_store_stubs do
      result = WebConfigurationService.configure_for_desktop(@link)

      assert_not_nil result[:linksquared]
      assert_equal "Test App", result[:linksquared]["title"]
      assert result[:linksquared]["qr"].present?
      assert_equal "https://example.com/fallback", result[:fallback]
    end
  end

  test "desktop with empty string fallback_url is treated as not set" do
    desktop_configurations(:one).update!(fallback_url: "")

    with_store_stubs do
      result = WebConfigurationService.configure_for_desktop(@link)

      assert_not_nil result[:linksquared]
      assert_equal "https://example.com/fallback", result[:fallback]
    end
  end

  test "desktop all redirect populates mac and windows configs" do
    with_store_stubs do
      result = WebConfigurationService.configure_for_desktop(@link)

      assert_equal "https://example.com/desktop-fallback", result[:mac]["fallback"]
      assert_equal result[:mac], result[:windows]
    end
  end

  test "desktop custom redirect keeps linksquared populated with the custom URL" do
    with_store_stubs do
      result = WebConfigurationService.configure_for_desktop(links(:basic_link))

      assert_not_nil result[:linksquared]
      assert_includes result[:linksquared]["fallback"], "desktop-custom"
    end
  end

  test "desktop payload never has both linksquared and fallback blank" do
    [nil, "", "https://example.com/desktop"].each do |url|
      desktop_configurations(:one).update!(fallback_url: url)
      # reload drops memoized associations so each iteration reads the updated config
      @link.reload

      with_store_stubs do
        result = WebConfigurationService.configure_for_desktop(@link)

        assert result[:linksquared].present? || result[:fallback].present?,
               "blank page: fallback_url=#{url.inspect} left neither linksquared nor fallback"
      end
    end
  end

  test "Android tracking_params always includes referrer even with no UTM" do
    pc = WebConfigurationService::PLATFORM_CONFIG[:android]
    link = OpenStruct.new(access_path: "https://example.sqd.link/test",
                          tracking_campaign: nil, tracking_source: nil, tracking_medium: nil)
    assert_equal [['referrer', 'https://example.sqd.link/test']], pc[:tracking_params].call(link)
  end

  test "copy_to_clipboard true with payload when link toggle and preview are on" do
    @link.update!(show_preview_ios: true, copy_to_clipboard_ios: true)

    with_store_stubs do
      result = WebConfigurationService.configuration_for_ios(@link, @device, @project)

      assert_equal true, result[:phone]["copy_to_clipboard"]
      assert result[:phone]["copy_payload"].start_with?(@link.access_path)
      assert_includes result[:phone]["copy_payload"], "gd=#{@device.hashid}"
    end
  end

  test "copy_to_clipboard inherits project default when link value is nil" do
    @link.update!(show_preview_ios: true, copy_to_clipboard_ios: nil)
    @link.redirect_config.update!(copy_to_clipboard_ios: true)

    with_store_stubs do
      result = WebConfigurationService.configuration_for_ios(@link, @device, @project)

      assert_equal true, result[:phone]["copy_to_clipboard"]
    end
  end

  test "link-level false overrides project-level true" do
    @link.update!(show_preview_ios: true, copy_to_clipboard_ios: false)
    @link.redirect_config.update!(copy_to_clipboard_ios: true)

    with_store_stubs do
      result = WebConfigurationService.configuration_for_ios(@link, @device, @project)

      assert_equal false, result[:phone]["copy_to_clipboard"]
      assert_nil result[:phone]["copy_payload"]
    end
  end

  test "copy_to_clipboard is false when preview is off even if toggle is on" do
    @link.update!(show_preview_ios: false, copy_to_clipboard_ios: true)

    with_store_stubs do
      result = WebConfigurationService.configuration_for_ios(@link, @device, @project)

      assert_equal false, result[:phone]["copy_to_clipboard"]
      assert_nil result[:phone]["copy_payload"]
    end
  end

  test "copy_to_clipboard defaults to false with untouched fixtures" do
    with_store_stubs do
      result = WebConfigurationService.configuration_for_ios(@link, @device, @project)

      assert_equal false, result[:phone]["copy_to_clipboard"]
      assert_nil result[:phone]["copy_payload"]
    end
  end

  test "custom redirect config carries copy keys when enabled" do
    link_with_custom = links(:basic_link)
    link_with_custom.update!(show_preview_ios: true, copy_to_clipboard_ios: true)

    with_store_stubs do
      result = WebConfigurationService.configuration_for_ios(link_with_custom, @device, @project)

      assert_equal true, result[:phone]["copy_to_clipboard"]
      assert_includes result[:phone]["copy_payload"], "gd=#{@device.hashid}"
    end
  end

  test "android copy_to_clipboard resolves from android columns" do
    @link.update!(show_preview_android: true, copy_to_clipboard_android: true)

    with_store_stubs do
      result = WebConfigurationService.configure_for_android(@link, @device, @project)

      assert_equal true, result[:phone]["copy_to_clipboard"]
    end
  end
end
