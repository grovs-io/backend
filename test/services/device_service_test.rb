require "test_helper"

class DeviceServiceTest < ActiveSupport::TestCase
  fixtures :instances, :projects, :devices, :visitors

  setup do
    @project = projects(:one)
    @base_env = { 'HTTP_ACCEPT_LANGUAGE' => 'en-US,en;q=0.9' }
    @request = OpenStruct.new(
      ip: "203.0.113.1",
      remote_ip: "198.51.100.1",
      user_agent: "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)",
      env: @base_env
    )
  end

  # --- build_new_device (via device_for_website_visit) ---

  test "build_new_device creates device with request user_agent when no override" do
    device = DeviceService.send(:build_new_device, @request, @project, nil)

    assert_equal "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)", device.user_agent
    assert_equal "203.0.113.1", device.ip
    assert_equal "198.51.100.1", device.remote_ip
    assert device.vendor.present?, "vendor should be auto-generated"
    assert_equal 64, device.vendor.length, "auto-generated vendor is a 32-byte hex string"
  end

  test "build_new_device extracts language from Accept-Language header" do
    device = DeviceService.send(:build_new_device, @request, @project, nil)

    assert_equal "en-US", device.language
  end

  test "build_new_device with nil Accept-Language sets language to nil" do
    request = OpenStruct.new(
      ip: "203.0.113.1",
      remote_ip: "198.51.100.1",
      user_agent: "TestAgent/1.0",
      env: {}
    )

    device = DeviceService.send(:build_new_device, request, @project, nil)

    assert_nil device.language
  end

  test "build_new_device with explicit platform uses it" do
    device = DeviceService.send(:build_new_device, @request, @project, Grovs::Platforms::ANDROID)

    assert_equal Grovs::Platforms::ANDROID, device.platform
  end

  test "build_new_device with nil platform falls back to user_agent detection" do
    device = DeviceService.send(:build_new_device, @request, @project, nil)

    # iPhone user agent should resolve to iOS
    assert_equal Grovs::Platforms::IOS, device.platform
  end

  test "build_new_device creates associated visitor for project" do
    device = DeviceService.send(:build_new_device, @request, @project, nil)

    visitor = Visitor.find_by(device: device, project: @project)
    assert_not_nil visitor, "visitor should be created for the project"
  end

  test "build_new_device persists both device and visitor" do
    device = DeviceService.send(:build_new_device, @request, @project, nil)

    assert device.persisted?, "device should be saved"
    assert Visitor.exists?(device: device, project: @project), "visitor should be saved"
  end

  # --- build_new_device with custom overrides (via create_new_device) ---

  test "build_new_device with custom vendor uses provided vendor" do
    device = DeviceService.send(:build_new_device, @request, @project, nil, vendor: "custom_vendor_123")

    assert_equal "custom_vendor_123", device.vendor
  end

  test "build_new_device with custom user_agent uses provided user_agent" do
    device = DeviceService.send(:build_new_device, @request, @project, nil, user_agent: "CustomApp/2.0 Android")

    assert_equal "CustomApp/2.0 Android", device.user_agent
  end

  test "build_new_device with custom user_agent still extracts language from request" do
    device = DeviceService.send(:build_new_device, @request, @project, nil,
      vendor: "v123", user_agent: "CustomApp/2.0")

    assert_equal "en-US", device.language
  end

  test "build_new_device with custom user_agent and nil platform uses custom UA for detection" do
    device = DeviceService.send(:build_new_device, @request, @project, nil,
      user_agent: "Mozilla/5.0 (Linux; Android 13; Pixel 7)")

    assert_equal Grovs::Platforms::ANDROID, device.platform
  end

  test "build_new_device with both vendor and user_agent overrides" do
    device = DeviceService.send(:build_new_device, @request, @project, Grovs::Platforms::IOS,
      vendor: "my_vendor", user_agent: "MyApp/1.0 iPhone")

    assert_equal "my_vendor", device.vendor
    assert_equal "MyApp/1.0 iPhone", device.user_agent
    assert_equal Grovs::Platforms::IOS, device.platform
    assert_equal "en-US", device.language
    assert device.persisted?
  end

  # --- create_new_device (public method, exercises build_new_device with overrides) ---

  test "create_new_device uses attrs vendor and user_agent" do
    attrs = DeviceService::DeviceAttributes.new(
      vendor: "sdk_vendor_abc",
      user_agent: "SdkApp/3.0 Android",
      platform: Grovs::Platforms::ANDROID,
      model: nil, build: nil, app_version: nil,
      screen_width: nil, screen_height: nil, timezone: nil,
      webgl_vendor: nil, webgl_renderer: nil, language: nil
    )

    device = DeviceService.create_new_device(@request, @project, attrs)

    assert_equal "sdk_vendor_abc", device.vendor
    assert_equal "SdkApp/3.0 Android", device.user_agent
    assert_equal Grovs::Platforms::ANDROID, device.platform
  end

  test "create_new_device generates vendor when attrs.vendor is nil" do
    attrs = DeviceService::DeviceAttributes.new(
      vendor: nil,
      user_agent: "SdkApp/3.0",
      platform: Grovs::Platforms::IOS,
      model: nil, build: nil, app_version: nil,
      screen_width: nil, screen_height: nil, timezone: nil,
      webgl_vendor: nil, webgl_renderer: nil, language: nil
    )

    device = DeviceService.create_new_device(@request, @project, attrs)

    assert device.vendor.present?
    assert_equal 64, device.vendor.length
  end
end
