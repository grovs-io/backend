require "test_helper"

class UpdateDeviceJobTest < ActiveSupport::TestCase
  fixtures :devices

  setup do
    @device = devices(:ios_device)
  end

  test "updates ip and remote_ip" do
    UpdateDeviceJob.new.perform(@device.id, "3.3.3.3", "4.4.4.4", "NewUA/1.0", nil)

    @device.reload
    assert_equal "3.3.3.3", @device.ip
    assert_equal "4.4.4.4", @device.remote_ip
  end

  test "prefers user_agent over request_user_agent" do
    UpdateDeviceJob.new.perform(@device.id, "1.1.1.1", "2.2.2.2", "DirectUA/2.0", "RequestUA/1.0")

    @device.reload
    assert_equal "DirectUA/2.0", @device.user_agent
  end

  test "falls back to request_user_agent when blank" do
    UpdateDeviceJob.new.perform(@device.id, "1.1.1.1", "2.2.2.2", "", "RequestUA/1.0")

    @device.reload
    assert_equal "RequestUA/1.0", @device.user_agent
  end

  test "platform uses param when present" do
    UpdateDeviceJob.new.perform(@device.id, "1.1.1.1", "2.2.2.2", "UA", nil,
                                nil, nil, nil, Grovs::Platforms::ANDROID)

    @device.reload
    assert_equal Grovs::Platforms::ANDROID, @device.platform
  end

  test "platform keeps existing when param blank" do
    original_platform = @device.platform

    UpdateDeviceJob.new.perform(@device.id, "1.1.1.1", "2.2.2.2", "UA", nil,
                                nil, nil, nil, nil)

    @device.reload
    assert_equal original_platform, @device.platform
  end

  test "skips optional attrs when nil" do
    @device.update_columns(model: "iPhone 15", build: "100")

    UpdateDeviceJob.new.perform(@device.id, "1.1.1.1", "2.2.2.2", "UA", nil,
                                nil, nil, nil, nil, nil)

    @device.reload
    assert_equal "iPhone 15", @device.model
    assert_equal "100", @device.build
  end

  test "clears redis cache for device with vendor" do
    @device.update_columns(vendor: "test-vendor-789")
    prefix = Device.cache_prefix

    deleted_keys = []
    REDIS.stub(:del, ->(*keys) { deleted_keys.concat(keys) }) do
      UpdateDeviceJob.new.perform(@device.id, "1.1.1.1", "2.2.2.2", "UA", nil)
    end

    vendor_key = deleted_keys.find { |k| k.include?("test-vendor-789") }
    assert vendor_key, "Should clear cache key containing the device vendor"
    assert deleted_keys.any? { |k| k.start_with?(prefix) }, "All keys should have the Device cache prefix"
  end

  test "clears old vendor cache key on vendor change" do
    @device.update_columns(vendor: "old-vendor-123")

    deleted_keys = []
    REDIS.stub(:del, ->(*keys) { deleted_keys.concat(keys) }) do
      UpdateDeviceJob.new.perform(@device.id, "1.1.1.1", "2.2.2.2", "UA", nil,
                                  nil, nil, nil, nil, "new-vendor-456")
    end

    assert deleted_keys.any? { |k| k.include?("old-vendor-123") }, "Should clear old vendor cache key"
    assert deleted_keys.any? { |k| k.include?("new-vendor-456") }, "Should clear new vendor cache key"
  end

  test "nonexistent device does not touch database" do
    assert_no_difference "Device.count" do
      result = UpdateDeviceJob.new.perform(-999, "1.1.1.1", "2.2.2.2", "UA", nil)
      assert_nil result
    end
  end
end
