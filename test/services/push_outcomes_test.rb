require "test_helper"

class PushOutcomesTest < ActiveSupport::TestCase
  fixtures :instances, :projects, :visitors, :devices

  test "dead_device clears only the token that failed" do
    devices(:ios_device).update_columns(push_token: "dead")
    PushOutcomes.dead_device(devices(:ios_device).id, "dead")
    assert_nil devices(:ios_device).reload.push_token
    devices(:ios_device).update_columns(push_token: "fresh")
    PushOutcomes.dead_device(devices(:ios_device).id, "dead")
    assert_equal "fresh", devices(:ios_device).reload.push_token, "a device that re-registered keeps its new token"
    assert_nothing_raised { PushOutcomes.dead_device(0, "x") }
  end

  test "outcomes never raise, even when the ee bookkeeping does" do
    assert_nothing_raised { PushOutcomes.delivered(nil) }
    assert_nothing_raised { PushOutcomes.failed(nil) }
    skip "ee only" unless defined?(PushDelivery)
    n = Rpush::Apnsp8::Notification.new(id: 1, device_token: "x", error_code: 500, error_description: "boom")
    PushDelivery.stub(:record_delivered_batch!, ->(*) { raise "db down" }) { assert_nothing_raised { PushOutcomes.delivered(n) } }
    PushDelivery.stub(:record_failed_batch!, ->(*) { raise "db down" }) { assert_nothing_raised { PushOutcomes.failed(n) } }
  end

  test "a dead-token failure settles the row and clears that device's token by id" do
    skip "ee only" unless defined?(PushDelivery)
    devices(:ios_device).update_columns(push_token: "gone")
    c = PushCampaign.create!(project: projects(:one), name: "n", title: "t", body: "b", status: "sending",
                             audience_type: "visitors", recipients: [visitors(:ios_visitor).uuid])
    PushDelivery.create!(push_campaign: c, visitor: visitors(:ios_visitor), device_id: devices(:ios_device).id, platform: "ios",
                         status: "queued", rpush_notification_id: 77)
    n = Rpush::Apnsp8::Notification.new(id: 77, device_token: "gone", error_code: 410, error_description: "Unregistered")
    PushOutcomes.failed(n)
    assert_nil devices(:ios_device).reload.push_token
    assert_equal "failed", c.deliveries.first.reload.status
    devices(:ios_device).update_columns(push_token: "again")
    PushOutcomes.failed(n)
    assert_equal "again", devices(:ios_device).reload.push_token, "an already settled row never clears a token twice"
  end

  test "a failure that is not a dead token keeps the device token" do
    skip "ee only" unless defined?(PushDelivery)
    devices(:ios_device).update_columns(push_token: "keep")
    c = PushCampaign.create!(project: projects(:one), name: "n", title: "t", body: "b", status: "sending",
                             audience_type: "visitors", recipients: [visitors(:ios_visitor).uuid])
    PushDelivery.create!(push_campaign: c, visitor: visitors(:ios_visitor), device_id: devices(:ios_device).id, platform: "ios",
                         status: "queued", rpush_notification_id: 78)
    PushOutcomes.failed(Rpush::Apnsp8::Notification.new(id: 78, device_token: "keep", error_code: 404, error_description: "BadPath"))
    assert_equal "keep", devices(:ios_device).reload.push_token
    assert_equal({ "BadPath" => 1 }, c.reload.error_counts)
  end

  test "without ee, failed is a no-op and opened is unavailable" do
    skip "ce only" if defined?(PushDelivery)
    devices(:ios_device).update_columns(push_token: "keep")
    PushOutcomes.failed(Rpush::Apnsp8::Notification.new(id: 1, device_token: "keep", error_code: 410, error_description: "Unregistered"))
    assert_equal "keep", devices(:ios_device).reload.push_token
    assert_equal :unavailable, PushOutcomes.opened(project: projects(:one), visitor: visitors(:ios_visitor), campaign_id: "x")
  end

  test "opened answers not_found for an unknown campaign and ok otherwise, counting once" do
    skip "ee only" unless defined?(PushDelivery)
    assert_equal :not_found, PushOutcomes.opened(project: projects(:one), visitor: visitors(:ios_visitor), campaign_id: "nope")
    c = PushCampaign.create!(project: projects(:one), name: "n", title: "t", body: "b", status: "sent",
                             audience_type: "visitors", recipients: [visitors(:ios_visitor).uuid])
    PushDelivery.create!(push_campaign: c, visitor: visitors(:ios_visitor), device_id: devices(:ios_device).id, platform: "ios", status: "delivered")
    assert_equal :ok, PushOutcomes.opened(project: projects(:one), visitor: visitors(:ios_visitor), campaign_id: c.hashid)
    assert_equal :noop, PushOutcomes.opened(project: projects(:one), visitor: visitors(:ios_visitor), campaign_id: c.hashid)
    assert_equal 1, c.reload.opened
  end
end
