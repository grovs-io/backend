require "test_helper"

class PushCampaigns::DelivererDailyCapRedisDownTest < ActiveSupport::TestCase
  include ConstStubHelper
  self.use_transactional_tests = false # the deliverer commits its own transaction; teardown cleans by hand
  fixtures :instances, :projects, :visitors, :devices

  class DownRedis
    def with = yield(self)
    def method_missing(*) = raise(Redis::CannotConnectError, "down")
    def respond_to_missing?(*) = true
  end

  setup do
    clear_caps
    devices(:ios_device).update_columns(push_token: "tok-ios")
    devices(:android_device).update_columns(push_token: "tok-android")
    InAppSetting.create!(project: projects(:one), push_daily_cap: 1)
    @campaign = PushCampaign.create!(project: projects(:one), name: "n", title: "t", body: "b", status: "sending",
                                     audience_type: "visitors", recipients: [visitors(:ios_visitor).uuid, visitors(:android_visitor).uuid])
    PushCampaigns::Audience.freeze!(@campaign)
    @apns = Rpush::Apnsp8::App.create!(name: "t-dev", environment: "development", apn_key: "k", apn_key_id: "id", team_id: "t", bundle_id: "b", connections: 1)
    @fcm = Rpush::Fcm::App.create!(name: "f", firebase_project_id: "p", json_key: "{}", connections: 1)
  end

  teardown do
    Rpush::Apnsp8::Notification.delete_all
    Rpush::Fcm::Notification.delete_all
    Rpush::Apnsp8::App.delete_all
    Rpush::Fcm::App.delete_all
    PushCampaign.delete_all
    InAppSetting.where(project: projects(:one)).delete_all
    devices(:ios_device).update_columns(push_token: nil)
    devices(:android_device).update_columns(push_token: nil)
    clear_caps
  end

  def clear_caps = REDIS.with { |c| c.keys("push:cap:#{projects(:one).id}:*").each { |k| c.del(k) } }

  def with_apps(&block)
    RpushService.stub(:app_for_platform, ->(platform, _p) { platform == "ios" ? @apns : @fcm }, &block)
  end

  test "with Redis down the daily cap fails open: pushes go out and nobody is failed as capped" do
    with_const(Object, :REDIS, DownRedis.new) do
      with_apps { assert_equal 2, PushCampaigns::Deliverer.new(@campaign).deliver_slice }
    end
    assert_equal %w[queued], @campaign.deliveries.distinct.pluck(:status)
    assert_equal 2, Rpush::Notification.count
    @campaign.reload
    assert_equal [2, 0, {}], [@campaign.queued, @campaign.failed, @campaign.error_counts]
  end

  test "a slice cancelled under it still settles as cancelled when the reservation cannot be given back" do
    deliverer = PushCampaigns::Deliverer.new(@campaign)
    original = deliverer.method(:claim)
    real = REDIS
    id = @campaign.id
    cancel = -> { with_const(Object, :REDIS, real) { PushCampaign.find(id).cancel! } }
    deliverer.define_singleton_method(:claim) { |now| original.call(now).tap { cancel.call } }
    with_const(Object, :REDIS, DownRedis.new) do
      with_apps { assert_equal false, deliverer.deliver_slice }
    end
    assert_equal 0, Rpush::Notification.count
    assert_equal %w[cancelled], @campaign.deliveries.distinct.pluck(:status)
    assert_equal [2, 0], @campaign.reload.values_at(:cancelled, :queued)
  end
end
