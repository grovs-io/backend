require "test_helper"

class PushCampaignPurgeJobTest < ActiveSupport::TestCase
  include ConstStubHelper
  fixtures :instances, :projects, :visitors, :devices

  test "a night's run is bounded; leftovers wait for the next one" do
    old = PushCampaign.create!(project: projects(:one), name: "o", title: "t", body: "b", status: "sent", finished_at: 31.days.ago,
                               audience_type: "visitors", recipients: [visitors(:ios_visitor).uuid])
    3.times do
      v = Visitor.create!(project: projects(:one), device: devices(:ios_device))
      PushDelivery.create!(push_campaign: old, visitor: v, device_id: devices(:ios_device).id, platform: "ios", status: "delivered")
    end
    with_const(PushCampaignPurgeJob, :BATCH, 1) do
      with_const(PushCampaignPurgeJob, :MAX_BATCHES, 2) { PushCampaignPurgeJob.new.perform }
    end
    assert_equal 1, old.deliveries.count
  end

  test "deliveries of old finished campaigns and old settled rpush rows are purged; counters stay" do
    old = PushCampaign.create!(project: projects(:one), name: "o", title: "t", body: "b", status: "sent", finished_at: 31.days.ago, queued: 1,
                               audience_type: "visitors", recipients: [visitors(:ios_visitor).uuid])
    fresh = PushCampaign.create!(project: projects(:one), name: "f", title: "t", body: "b", status: "sent", finished_at: 1.day.ago,
                                 audience_type: "visitors", recipients: [visitors(:ios_visitor).uuid])
    [old, fresh].each do |c|
      PushDelivery.create!(push_campaign: c, visitor: visitors(:ios_visitor), device_id: devices(:ios_device).id, platform: "ios", status: "delivered")
    end
    app = Rpush::Apnsp8::App.create!(name: "t-dev", environment: "development", apn_key: "k", apn_key_id: "id", team_id: "t", bundle_id: "b", connections: 1)
    stale = Rpush::Apnsp8::Notification.create!(app: app, device_token: "a" * 64, alert: "x", delivered: true, created_at: 8.days.ago)
    live = Rpush::Apnsp8::Notification.create!(app: app, device_token: "b" * 64, alert: "x", delivered: false, created_at: 8.days.ago)
    PushCampaignPurgeJob.new.perform
    assert_equal 0, old.deliveries.count
    assert_equal 1, fresh.deliveries.count
    assert_equal 1, old.reload.queued
    assert_nil Rpush::Notification.find_by(id: stale.id)
    assert Rpush::Notification.find_by(id: live.id)
  ensure
    Rpush::Apnsp8::Notification.delete_all
    Rpush::Apnsp8::App.delete_all
  end
end
