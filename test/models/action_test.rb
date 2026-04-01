require "test_helper"

class ActionTest < ActiveSupport::TestCase
  fixtures :devices, :domains, :projects, :redirect_configs

  # === serialization ===

  test "serializer includes nested device and link objects with their own attributes" do
    link = Link.create!(
      domain: domains(:one),
      redirect_config: redirect_configs(:one),
      path: "action-test-path-2",
      generated_from_platform: Grovs::Platforms::IOS
    )
    device = devices(:ios_device)
    action = Action.create!(device: device, link: link)
    json = ActionSerializer.serialize(action)

    assert_not_nil json["device"], "serializer should include device object"
    assert_not_nil json["link"], "serializer should include link object"

    # Verify the device is a full object, not just an ID
    assert_equal device.id, json["device"]["id"]
    assert_equal device.platform, json["device"]["platform"]

    # Verify the link is a full object, not just an ID
    assert_equal link.id, json["link"]["id"]
    assert_equal "action-test-path-2", json["link"]["path"]
  end
end
