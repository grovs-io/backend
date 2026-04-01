require "test_helper"

class InstalledAppTest < ActiveSupport::TestCase
  fixtures :devices, :projects, :instances, :installed_apps

  test "fetch_for_device_and_project returns record when it exists" do
    existing = installed_apps(:one) # device: ios_device, project: one

    result = InstalledApp.fetch_for_device_and_project(existing.device_id, existing.project_id)
    assert_not_nil result
    assert_equal existing.device_id, result.device_id
    assert_equal existing.project_id, result.project_id
  end

  test "fetch_for_device_and_project returns nil when no record exists" do
    result = InstalledApp.fetch_for_device_and_project(-999, -999)
    assert_nil result
  end
end
