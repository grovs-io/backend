# frozen_string_literal: true

require "test_helper"

class DeviceLastSeenTest < ActiveSupport::TestCase
  fixtures :instances, :projects, :applications, :devices, :visitors, :domains

  setup do
    @project = projects(:one)
    @device = devices(:ios_device)
  end

  test "stamp_batch! inserts a row with the event time" do
    at = 5.minutes.ago
    DeviceLastSeen.stamp_batch!({ [@project.id, @device.id] => at })

    assert_in_delta at.to_f, DeviceLastSeen.find_by!(project_id: @project.id, device_id: @device.id).last_seen_at.to_f, 0.001
  end

  test "stamp_batch! never regresses an existing newer stamp" do
    newer = 1.minute.ago
    DeviceLastSeen.stamp_batch!({ [@project.id, @device.id] => newer })
    DeviceLastSeen.stamp_batch!({ [@project.id, @device.id] => 2.days.ago })

    assert_in_delta newer.to_f, DeviceLastSeen.find_by!(project_id: @project.id, device_id: @device.id).last_seen_at.to_f, 0.001
  end

  test "stamp_batch! advances an older stamp" do
    DeviceLastSeen.stamp_batch!({ [@project.id, @device.id] => 2.days.ago })
    newer = 1.minute.ago
    DeviceLastSeen.stamp_batch!({ [@project.id, @device.id] => newer })

    assert_in_delta newer.to_f, DeviceLastSeen.find_by!(project_id: @project.id, device_id: @device.id).last_seen_at.to_f, 0.001
  end

  test "stamp_batch! clamps future-dated event times to now" do
    DeviceLastSeen.stamp_batch!({ [@project.id, @device.id] => 20.years.from_now })

    assert_in_delta Time.current.to_f, DeviceLastSeen.find_by!(project_id: @project.id, device_id: @device.id).last_seen_at.to_f, 2.0
  end
end
