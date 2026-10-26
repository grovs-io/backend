require "test_helper"

class PushOutcomesDeadTokenBatchTest < ActiveSupport::TestCase
  include ConstStubHelper
  fixtures :instances, :projects, :visitors, :devices

  class FirstDelFails
    attr_reader :failed

    def initialize(real)
      @real = real
      @failed = false
    end

    def del(*keys)
      return @real.del(*keys) if @failed

      @failed = true
      raise Redis::CannotConnectError, "down"
    end

    def method_missing(name, ...) = @real.public_send(name, ...)
    def respond_to_missing?(*) = true
  end

  setup do
    devices(:ios_device).update_columns(push_token: "gone-ios")
    devices(:android_device).update_columns(push_token: "gone-android")
    @campaign = PushCampaign.create!(project: projects(:one), name: "n", title: "t", body: "b", status: "sending",
                                     audience_type: "visitors", recipients: [visitors(:ios_visitor).uuid, visitors(:android_visitor).uuid])
    [[visitors(:ios_visitor), devices(:ios_device), 91], [visitors(:android_visitor), devices(:android_device), 92]].each do |visitor, device, rpush_id|
      PushDelivery.create!(push_campaign: @campaign, visitor: visitor, device_id: device.id, platform: "ios", status: "queued",
                           rpush_notification_id: rpush_id)
    end
  end

  def notifications = [91, 92].zip(%w[gone-ios gone-android]).map { |id, token| Rpush::Apnsp8::Notification.new(id: id, device_token: token) }

  test "a cache clear failing for one dead device still clears the other devices of the batch" do
    redis = FirstDelFails.new(REDIS)
    with_const(Object, :REDIS, redis) { PushOutcomes.failed_batch(notifications, 410, "Unregistered") }
    assert redis.failed
    assert_equal [nil, nil], [devices(:ios_device).reload.push_token, devices(:android_device).reload.push_token]
    assert_equal %w[failed], @campaign.deliveries.distinct.pluck(:status)
    assert_equal({ "Unregistered" => 2 }, @campaign.reload.error_counts)
  end

  test "in one BadDeviceToken batch only the sandbox app's token is kept; the production app's is cleared" do
    sandbox = Rpush::Apnsp8::App.create!(name: "s", environment: "development", apn_key: "k", apn_key_id: "id", team_id: "t", bundle_id: "b", connections: 1)
    prod = Rpush::Apnsp8::App.create!(name: "p", environment: "production", apn_key: "k", apn_key_id: "id", team_id: "t", bundle_id: "b", connections: 1)
    batch = notifications.each_with_index { |n, i| n.app_id = [sandbox, prod][i].id }
    PushOutcomes.failed_batch(batch, 400, "BadDeviceToken")
    assert_equal ["gone-ios", nil], [devices(:ios_device).reload.push_token, devices(:android_device).reload.push_token]
    assert_equal({ "BadDeviceToken" => 2 }, @campaign.reload.error_counts)
  end
end
