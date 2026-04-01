require "test_helper"

class DeviceCreationServiceTest < ActiveSupport::TestCase
  fixtures :instances, :projects, :devices, :visitors

  setup do
    @project = projects(:one)
    @base_env = { "HTTP_ACCEPT_LANGUAGE" => "en-US,en;q=0.9" }
    @request = OpenStruct.new(
      ip: "203.0.113.50",
      remote_ip: "198.51.100.50",
      user_agent: "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)",
      env: @base_env
    )
  end

  # --- build_new_device ---

  test "build_new_device creates persisted device with request attributes" do
    device = DeviceCreationService.build_new_device(@request, @project, Grovs::Platforms::IOS)

    assert device.persisted?
    assert_equal "203.0.113.50", device.ip
    assert_equal "198.51.100.50", device.remote_ip
    assert_equal Grovs::Platforms::IOS, device.platform
    assert_equal @request.user_agent, device.user_agent
  end

  test "build_new_device auto-generates vendor when nil" do
    device = DeviceCreationService.build_new_device(@request, @project, nil)

    assert device.vendor.present?
    assert_equal 64, device.vendor.length, "auto-generated vendor is 32-byte hex"
  end

  test "build_new_device uses provided vendor" do
    device = DeviceCreationService.build_new_device(@request, @project, nil, vendor: "my_vendor_id")

    assert_equal "my_vendor_id", device.vendor
  end

  test "build_new_device uses provided user_agent over request" do
    device = DeviceCreationService.build_new_device(@request, @project, nil, user_agent: "CustomApp/2.0")

    assert_equal "CustomApp/2.0", device.user_agent
  end

  test "build_new_device extracts language from Accept-Language header" do
    device = DeviceCreationService.build_new_device(@request, @project, nil)

    assert_equal "en-US", device.language
  end

  test "build_new_device with nil Accept-Language sets language nil" do
    request = OpenStruct.new(ip: "1.2.3.4", remote_ip: "5.6.7.8", user_agent: "Test/1.0", env: {})

    device = DeviceCreationService.build_new_device(request, @project, nil)

    assert_nil device.language
  end

  test "build_new_device with nil platform detects from user_agent" do
    device = DeviceCreationService.build_new_device(@request, @project, nil)

    assert_equal Grovs::Platforms::IOS, device.platform
  end

  test "build_new_device creates visitor for the project" do
    device = DeviceCreationService.build_new_device(@request, @project, nil)

    visitor = Visitor.find_by(device: device, project: @project)
    assert_not_nil visitor
    assert visitor.persisted?
  end

  # --- create_new_device ---

  test "create_new_device sets full device data from attrs" do
    attrs = DeviceService::DeviceAttributes.new(
      vendor: "sdk_vendor_full",
      user_agent: "SdkApp/3.0 Android",
      model: "Pixel 8",
      build: "20260319",
      app_version: "3.0.1",
      platform: Grovs::Platforms::ANDROID,
      screen_width: 1080,
      screen_height: 2400,
      timezone: "Europe/Berlin",
      webgl_vendor: nil,
      webgl_renderer: nil,
      language: "de"
    )

    device = DeviceCreationService.create_new_device(@request, @project, attrs)

    assert device.persisted?
    assert_equal "sdk_vendor_full", device.vendor
    assert_equal "Pixel 8", device.model
    assert_equal "20260319", device.build
    assert_equal "3.0.1", device.app_version
    assert_equal Grovs::Platforms::ANDROID, device.platform
    assert_equal 1080, device.screen_width
    assert_equal 2400, device.screen_height
    assert_equal "Europe/Berlin", device.timezone
    assert_equal "de", device.language
  end

  test "create_new_device generates vendor when attrs.vendor is nil" do
    attrs = DeviceService::DeviceAttributes.new(
      vendor: nil, user_agent: "App/1.0", model: nil, build: nil,
      app_version: nil, platform: Grovs::Platforms::IOS,
      screen_width: nil, screen_height: nil, timezone: nil,
      webgl_vendor: nil, webgl_renderer: nil, language: nil
    )

    device = DeviceCreationService.create_new_device(@request, @project, attrs)

    assert device.vendor.present?
    assert_equal 64, device.vendor.length
  end

  test "create_new_device creates visitor for project" do
    attrs = DeviceService::DeviceAttributes.new(
      vendor: "visitor_test_vendor", user_agent: "App/1.0", model: nil, build: nil,
      app_version: nil, platform: Grovs::Platforms::IOS,
      screen_width: nil, screen_height: nil, timezone: nil,
      webgl_vendor: nil, webgl_renderer: nil, language: nil
    )

    device = DeviceCreationService.create_new_device(@request, @project, attrs)

    assert Visitor.exists?(device: device, project: @project)
  end

  # --- update_device_with_full_data ---

  test "update_device_with_full_data updates all fields" do
    device = DeviceCreationService.build_new_device(@request, @project, nil)

    new_request = OpenStruct.new(ip: "10.0.0.99", remote_ip: "10.0.0.100", user_agent: "X", env: {})

    DeviceCreationService.update_device_with_full_data(
      device, new_request, "new_vendor", "Galaxy S24", "build_99", "5.0.0", Grovs::Platforms::ANDROID,
      screen_width: 1440, screen_height: 3200, timezone: "Asia/Tokyo", language: "ja"
    )

    device.reload
    assert_equal "10.0.0.99", device.ip
    assert_equal "10.0.0.100", device.remote_ip
    assert_equal "new_vendor", device.vendor
    assert_equal "Galaxy S24", device.model
    assert_equal "build_99", device.build
    assert_equal "5.0.0", device.app_version
    assert_equal Grovs::Platforms::ANDROID, device.platform
    assert_equal 1440, device.screen_width
    assert_equal 3200, device.screen_height
    assert_equal "Asia/Tokyo", device.timezone
    assert_equal "ja", device.language
  end

  test "update_device_with_full_data skips nil optional fields" do
    device = DeviceCreationService.build_new_device(@request, @project, Grovs::Platforms::IOS)
    original_language = device.language

    DeviceCreationService.update_device_with_full_data(
      device, @request, nil, "iPhone 15", "build_1", "2.0", Grovs::Platforms::IOS
    )

    device.reload
    assert_equal original_language, device.language
  end

  # --- generate_vendor_id ---

  test "generate_vendor_id returns unique 64-char hex string" do
    vendor = DeviceCreationService.generate_vendor_id

    assert_equal 64, vendor.length
    assert_match(/\A[0-9a-f]{64}\z/, vendor)
  end

  test "generate_vendor_id returns different values on successive calls" do
    v1 = DeviceCreationService.generate_vendor_id
    v2 = DeviceCreationService.generate_vendor_id

    assert_not_equal v1, v2
  end
end
