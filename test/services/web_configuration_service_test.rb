require "test_helper"

class WebConfigurationServiceTest < ActiveSupport::TestCase
  fixtures :instances, :projects, :links, :domains, :redirect_configs, :redirects,
           :applications, :ios_configurations, :android_configurations, :devices, :visitors,
           :custom_redirects

  setup do
    @project = projects(:one)
    @instance = instances(:one)
    @link = links(:second_link) # no custom redirects
    @device = devices(:ios_device)

    @ios_store_result = { title: "Test App", image: "https://example.com/icon.png", appstore_id: "123456789" }
    @android_store_result = { title: "Test App", image: "https://example.com/icon.png" }
  end

  # --- Custom redirect bypasses appstore/deeplink ---

  test "custom redirect sets fallback to custom URL and nils out deeplink and appstore" do
    link_with_custom = links(:basic_link)

    AppstoreService.stub(:fetch_image_and_title_for_identifier, @ios_store_result) do
      GooglePlayService.stub(:fetch_image_and_title_for_identifier, @android_store_result) do
        result = WebConfigurationService.configuration_for_ios(link_with_custom, @device, @project)

        assert_includes result[:phone]["fallback"], "ios-custom"
        assert_nil result[:phone]["deeplink"]
        assert_nil result[:phone]["appstore"]
      end
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

  test "Android tracking_params always includes referrer even with no UTM" do
    pc = WebConfigurationService::PLATFORM_CONFIG[:android]
    link = OpenStruct.new(access_path: "https://example.sqd.link/test",
                          tracking_campaign: nil, tracking_source: nil, tracking_medium: nil)
    assert_equal [['referrer', 'https://example.sqd.link/test']], pc[:tracking_params].call(link)
  end
end
