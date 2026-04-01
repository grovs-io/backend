require "test_helper"
require "sidekiq/testing"

class DeviceUpdateServiceTest < ActiveSupport::TestCase
  fixtures :instances, :projects, :devices, :visitors

  setup do
    @project = projects(:one)
    @device = devices(:ios_device)
    @base_env = { "HTTP_ACCEPT_LANGUAGE" => "en-US" }

    Sidekiq::Testing.fake!
    UpdateDeviceJob.jobs.clear
  end

  teardown do
    Sidekiq::Testing.disable!
  end

  # --- update_device (async): enqueue behavior ---

  test "update_device enqueues job when IP changes" do
    request = OpenStruct.new(
      ip: "99.99.99.99",
      remote_ip: @device.remote_ip,
      user_agent: @device.user_agent,
      env: @base_env
    )

    stub_redis_dedup_allows do
      DeviceUpdateService.update_device(@device, request, nil)
    end

    assert_equal 1, UpdateDeviceJob.jobs.size
  end

  test "update_device enqueues job when user_agent changes" do
    request = OpenStruct.new(
      ip: @device.ip,
      remote_ip: @device.remote_ip,
      user_agent: @device.user_agent,
      env: @base_env
    )

    stub_redis_dedup_allows do
      DeviceUpdateService.update_device(@device, request, "NewAgent/2.0")
    end

    assert_equal 1, UpdateDeviceJob.jobs.size
  end

  test "update_device passes correct args to job" do
    request = OpenStruct.new(
      ip: "55.66.77.88",
      remote_ip: "99.88.77.66",
      user_agent: "RequestUA/1.0",
      env: @base_env
    )

    stub_redis_dedup_allows do
      DeviceUpdateService.update_device(@device, request, "ExplicitUA/2.0")
    end

    job = UpdateDeviceJob.jobs.last
    assert_not_nil job, "job should be enqueued"
    assert_equal @device.id, job["args"][0]
    assert_equal "55.66.77.88", job["args"][1]
    assert_equal "99.88.77.66", job["args"][2]
    assert_equal "ExplicitUA/2.0", job["args"][3]
    assert_equal "RequestUA/1.0", job["args"][4]
  end

  # --- update_device: skip behavior ---

  test "update_device skips job when nothing changed and device is fresh" do
    @device.update_column(:updated_at, Time.current)

    request = OpenStruct.new(
      ip: @device.ip,
      remote_ip: @device.remote_ip,
      user_agent: @device.user_agent,
      env: @base_env
    )

    DeviceUpdateService.update_device(@device, request, nil)

    assert_equal 0, UpdateDeviceJob.jobs.size
  end

  test "update_device touches updated_at when nothing changed but device is stale" do
    @device.update_column(:updated_at, 5.minutes.ago)
    old_updated_at = @device.updated_at

    request = OpenStruct.new(
      ip: @device.ip,
      remote_ip: @device.remote_ip,
      user_agent: @device.user_agent,
      env: @base_env
    )

    DeviceUpdateService.update_device(@device, request, nil)

    @device.reload
    assert @device.updated_at > old_updated_at, "updated_at should be refreshed for stale device"
  end

  # --- update_device: dedup ---

  test "update_device dedup prevents duplicate jobs via Redis NX" do
    # Use a fresh device to avoid parallel test interference
    device = DeviceCreationService.build_new_device(
      OpenStruct.new(ip: "1.1.1.1", remote_ip: "2.2.2.2", user_agent: "UA/1", env: {}),
      @project, nil
    )
    REDIS.with { |conn| conn.del("dev_upd_basic:#{device.id}") }
    UpdateDeviceJob.jobs.clear

    request = OpenStruct.new(
      ip: "11.22.33.44",
      remote_ip: device.remote_ip,
      user_agent: device.user_agent,
      env: @base_env
    )

    DeviceUpdateService.update_device(device, request, nil)
    assert_equal 1, UpdateDeviceJob.jobs.size

    DeviceUpdateService.update_device(device, request, nil)
    assert_equal 1, UpdateDeviceJob.jobs.size, "dedup should prevent second job"
  end

  # --- update_device_sync ---

  test "update_device_sync updates device attributes synchronously" do
    request = OpenStruct.new(
      ip: "77.77.77.77",
      remote_ip: "88.88.88.88",
      user_agent: "SyncAgent/1.0",
      env: @base_env
    )

    DeviceUpdateService.update_device_sync(@device, request, "ExplicitUA/2.0")

    @device.reload
    assert_equal "77.77.77.77", @device.ip
    assert_equal "88.88.88.88", @device.remote_ip
    assert_equal "ExplicitUA/2.0", @device.user_agent
  end

  test "update_device_sync falls back to request user_agent when explicit is nil" do
    request = OpenStruct.new(
      ip: "77.77.77.77",
      remote_ip: "88.88.88.88",
      user_agent: "FallbackUA/1.0",
      env: @base_env
    )

    DeviceUpdateService.update_device_sync(@device, request, nil)

    @device.reload
    assert_equal "FallbackUA/1.0", @device.user_agent
  end

  test "update_device_sync returns nil for nil device" do
    request = OpenStruct.new(ip: "1.2.3.4", remote_ip: "5.6.7.8", user_agent: "X", env: {})

    result = DeviceUpdateService.update_device_sync(nil, request, nil)

    assert_nil result
  end

  # --- set_device_data_async: enqueue ---

  test "set_device_data_async enqueues job when model changes" do
    attrs = DeviceService::DeviceAttributes.new(
      vendor: @device.vendor,
      user_agent: @device.user_agent,
      model: "New Model XYZ",
      build: @device.build,
      app_version: @device.app_version,
      platform: @device.platform,
      screen_width: @device.screen_width,
      screen_height: @device.screen_height,
      timezone: @device.timezone,
      webgl_vendor: nil,
      webgl_renderer: nil,
      language: @device.language
    )

    request = OpenStruct.new(
      ip: @device.ip,
      remote_ip: @device.remote_ip,
      user_agent: @device.user_agent,
      env: @base_env
    )

    stub_redis_dedup_allows do
      DeviceUpdateService.set_device_data_async(@device, request, attrs)
    end

    assert_equal 1, UpdateDeviceJob.jobs.size
  end

  # --- set_device_data_async: skip ---

  test "set_device_data_async skips when all attrs match device" do
    attrs = DeviceService::DeviceAttributes.new(
      vendor: @device.vendor,
      user_agent: @device.user_agent,
      model: @device.model,
      build: @device.build,
      app_version: @device.app_version,
      platform: @device.platform,
      screen_width: @device.screen_width,
      screen_height: @device.screen_height,
      timezone: @device.timezone,
      webgl_vendor: nil,
      webgl_renderer: nil,
      language: @device.language
    )

    request = OpenStruct.new(
      ip: @device.ip,
      remote_ip: @device.remote_ip,
      user_agent: @device.user_agent,
      env: @base_env
    )

    DeviceUpdateService.set_device_data_async(@device, request, attrs)

    assert_equal 0, UpdateDeviceJob.jobs.size
  end

  test "set_device_data_async skips blank attrs in comparison" do
    attrs = DeviceService::DeviceAttributes.new(
      vendor: nil,
      user_agent: @device.user_agent,
      model: nil,
      build: nil,
      app_version: nil,
      platform: nil,
      screen_width: nil,
      screen_height: nil,
      timezone: nil,
      webgl_vendor: nil,
      webgl_renderer: nil,
      language: nil
    )

    request = OpenStruct.new(
      ip: @device.ip,
      remote_ip: @device.remote_ip,
      user_agent: @device.user_agent,
      env: @base_env
    )

    DeviceUpdateService.set_device_data_async(@device, request, attrs)

    assert_equal 0, UpdateDeviceJob.jobs.size
  end

  # --- set_device_data_async: dedup ---

  test "set_device_data_async dedup prevents duplicate full-update jobs" do
    # Use a fresh device to avoid parallel test interference
    device = DeviceCreationService.build_new_device(
      OpenStruct.new(ip: "1.1.1.1", remote_ip: "2.2.2.2", user_agent: "UA/1", env: {}),
      @project, nil
    )
    REDIS.with { |conn| conn.del("dev_upd_full:#{device.id}") }
    UpdateDeviceJob.jobs.clear

    attrs = DeviceService::DeviceAttributes.new(
      vendor: device.vendor,
      user_agent: device.user_agent,
      model: "Changed Model",
      build: nil, app_version: nil, platform: nil,
      screen_width: nil, screen_height: nil, timezone: nil,
      webgl_vendor: nil, webgl_renderer: nil, language: nil
    )

    request = OpenStruct.new(
      ip: device.ip,
      remote_ip: device.remote_ip,
      user_agent: device.user_agent,
      env: @base_env
    )

    DeviceUpdateService.set_device_data_async(device, request, attrs)
    assert_equal 1, UpdateDeviceJob.jobs.size

    DeviceUpdateService.set_device_data_async(device, request, attrs)
    assert_equal 1, UpdateDeviceJob.jobs.size, "dedup should prevent second job"
  end

  private

  # Stub REDIS.set to always return true, bypassing dedup.
  # Use this for tests that verify enqueue behavior, not dedup behavior.
  def stub_redis_dedup_allows(&block)
    REDIS.stub(:set, true, &block)
  end
end
