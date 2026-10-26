require "test_helper"

class PushCampaigns::DelivererTest < ActiveSupport::TestCase
  include ConstStubHelper
  self.use_transactional_tests = false # two real connections must see claimed rows; teardown cleans by hand
  fixtures :instances, :projects, :visitors, :devices

  setup do
    @extra_visitor_ids = []
    devices(:ios_device).update_columns(push_token: "tok-ios")
    devices(:android_device).update_columns(push_token: "tok-android")
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
    Visitor.where(id: @extra_visitor_ids).delete_all
    if @extra_device
      DeviceLastSeen.where(device_id: @extra_device.id).delete_all
      @extra_device.delete
    end
    devices(:ios_device).update_columns(push_token: nil)
    devices(:android_device).update_columns(push_token: nil)
  end

  def with_apps(&block)
    RpushService.stub(:app_for_platform, ->(platform, _p) { platform == "ios" ? @apns : @fcm }, &block)
  end

  test "a slice creates one rpush row per pending delivery and marks them queued" do
    with_apps { assert_equal 2, PushCampaigns::Deliverer.new(@campaign).deliver_slice }
    rows = @campaign.deliveries.where(status: "queued").order(:platform)
    assert_equal 2, rows.count
    assert_equal 1, Rpush::Apnsp8::Notification.count
    assert_equal 1, Rpush::Fcm::Notification.count
    assert_equal Rpush::Fcm::Notification.first.id, rows.first.rpush_notification_id
    assert_equal 2, @campaign.reload.queued
  end

  test "a slice waits while rpush is behind" do
    with_const(PushCampaigns::Deliverer, :MAX_RPUSH_BACKLOG, 1) do
      Rpush::Apnsp8::Notification.create!(app: @apns, device_token: "z" * 64, alert: "x")
      with_apps { assert_equal :throttled, PushCampaigns::Deliverer.new(@campaign).deliver_slice }
      assert_equal 2, @campaign.deliveries.where(status: "pending").count

      Rpush::Apnsp8::Notification.update_all(delivered: true)
      with_apps { assert_equal 2, PushCampaigns::Deliverer.new(@campaign).deliver_slice }
    end
  end

  test "another project's rpush backlog also holds the slice back" do
    other = Rpush::Apnsp8::App.create!(name: "other-dev", environment: "development", apn_key: "k", apn_key_id: "id", team_id: "t",
                                       bundle_id: "b", connections: 1)
    with_const(PushCampaigns::Deliverer, :MAX_RPUSH_BACKLOG, 1) do
      Rpush::Apnsp8::Notification.create!(app: other, device_token: "z" * 64, alert: "x")
      with_apps { assert_equal :throttled, PushCampaigns::Deliverer.new(@campaign).deliver_slice }
    end
  end

  test "pushes parked for a later retry do not hold the slice back" do
    with_const(PushCampaigns::Deliverer, :MAX_RPUSH_BACKLOG, 1) do
      Rpush::Apnsp8::Notification.create!(app: @apns, device_token: "z" * 64, alert: "x", deliver_after: 1.minute.from_now)
      with_apps { assert_equal 2, PushCampaigns::Deliverer.new(@campaign).deliver_slice }
    end
  end

  test "a slice claimed before a cancel is not handed to rpush" do
    deliverer = PushCampaigns::Deliverer.new(@campaign)
    original = deliverer.method(:claim)
    deliverer.define_singleton_method(:claim) do |now|
      original.call(now).tap { PushCampaign.find(@campaign.id).cancel! }
    end
    with_apps { assert_equal false, deliverer.deliver_slice }
    assert_equal 0, Rpush::Notification.count
    assert_equal %w[cancelled], @campaign.deliveries.distinct.pluck(:status)
    @campaign.reload
    assert_equal [2, 0], [@campaign.cancelled, @campaign.queued]
  end

  test "the backlog is re-read on every slice even under the job's query cache" do
    with_const(PushCampaigns::Deliverer, :MAX_RPUSH_BACKLOG, 1) do
      backlog = Rpush::Apnsp8::Notification.create!(app: @apns, device_token: "z" * 64, alert: "x")
      ActiveRecord::Base.cache do
        with_apps do
          deliverer = PushCampaigns::Deliverer.new(@campaign)
          assert_equal :throttled, deliverer.deliver_slice
          # rpush settles from its own process; a write here would clear the cache and hide the bug.
          Thread.new { ActiveRecord::Base.connection_pool.with_connection { backlog.update_columns(delivered: true) } }.join
          assert_equal 2, deliverer.deliver_slice
        end
      end
    end
  end

  test "nothing due returns false; a future due_at is left alone" do
    @campaign.deliveries.update_all(due_at: 1.hour.from_now)
    with_apps { assert_equal false, PushCampaigns::Deliverer.new(@campaign).deliver_slice }
    assert_equal 2, @campaign.deliveries.where(status: "pending").count
  end

  test "a missing app fails those rows with no_app and counts the error" do
    RpushService.stub(:app_for_platform, ->(platform, _p) { platform == "ios" ? @apns : nil }) do
      assert_equal 2, PushCampaigns::Deliverer.new(@campaign).deliver_slice
    end
    row = @campaign.deliveries.find_by(platform: "android")
    assert_equal %w[failed no_app], [row.status, row.error]
    @campaign.reload
    assert_equal [1, 1, { "no_app" => 1 }], [@campaign.queued, @campaign.failed, @campaign.error_counts]
  end

  test "a token cleared after freezing fails the row with no_token" do
    devices(:ios_device).update_columns(push_token: nil)
    with_apps { PushCampaigns::Deliverer.new(@campaign).deliver_slice }
    assert_equal "no_token", @campaign.deliveries.find_by(platform: "ios").error
  end

  test "a slice with two failure kinds settles in one statement" do
    devices(:ios_device).update_columns(push_token: nil)
    RpushService.stub(:app_for_platform, ->(platform, _p) { platform == "ios" ? @apns : nil }) do
      assert_equal 2, PushCampaigns::Deliverer.new(@campaign).deliver_slice
    end
    assert_equal({ "no_token" => 1, "no_app" => 1 }, @campaign.reload.error_counts)
    assert_equal 0, @campaign.deliveries.where(status: "claimed").count
  end

  test "two concurrent claimers never take the same row" do
    @extra_device = Device.create!(user_agent: "ua", ip: "1.1.1.1", remote_ip: "1.1.1.1", platform: "ios", vendor: "race-vendor", push_token: "tok")
    30.times do
      v = Visitor.create!(project: projects(:one), device: @extra_device)
      @extra_visitor_ids << v.id
      PushDelivery.create!(push_campaign: @campaign, visitor: v, device_id: @extra_device.id, platform: "ios",
                           status: "pending", due_at: Time.current, recipient: v.uuid)
    end
    with_const(PushCampaigns::Deliverer, :SLICE, 7) do
      with_apps do
        Array.new(2) do
          Thread.new { ActiveRecord::Base.connection_pool.with_connection { 3.times { PushCampaigns::Deliverer.new(@campaign).deliver_slice } } }
        end.each(&:join)
      end
    end
    assert_equal @campaign.deliveries.where(status: "queued").count, Rpush::Apnsp8::Notification.count + Rpush::Fcm::Notification.count
    assert_equal 0, @campaign.deliveries.where(status: "claimed").count
  end

  test "a slice is all-or-nothing: a failed delivery update leaves no orphan rpush rows" do
    PushDelivery.stub(:upsert_all, ->(*) { raise ActiveRecord::StatementInvalid, "boom" }) do
      with_apps { assert_raises(ActiveRecord::StatementInvalid) { PushCampaigns::Deliverer.new(@campaign).deliver_slice } }
    end
    assert_equal 0, Rpush::Apnsp8::Notification.count + Rpush::Fcm::Notification.count
    assert_equal 2, @campaign.deliveries.where(status: "claimed").count, "the tick resets these; without the transaction they would be pushed twice"
  end

  test "a slice that stalls past the stale reset leaves its rows to the claimer that took them over" do
    stalled = PushCampaigns::Deliverer.new(@campaign)
    original = stalled.method(:claim)
    stalled.define_singleton_method(:claim) do |now|
      original.call(now).tap do
        PushDelivery.where(push_campaign_id: @campaign.id, status: "claimed").update_all(status: "pending", updated_at: Time.current)
        PushCampaigns::Deliverer.new(@campaign).deliver_slice
      end
    end
    with_apps { stalled.deliver_slice }
    assert_equal 2, Rpush::Apnsp8::Notification.count + Rpush::Fcm::Notification.count
    assert_equal 2, @campaign.deliveries.where(status: "queued").distinct.count(:rpush_notification_id)
    assert_equal 2, @campaign.reload.queued
  end

  test "a slice reset to pending but not yet reclaimed is not pushed by the stalled claimer" do
    stalled = PushCampaigns::Deliverer.new(@campaign)
    original = stalled.method(:claim)
    stalled.define_singleton_method(:claim) do |now|
      original.call(now).tap { PushDelivery.where(push_campaign_id: @campaign.id).update_all(status: "pending", updated_at: Time.current) }
    end
    with_apps { stalled.deliver_slice }
    assert_equal 0, Rpush::Apnsp8::Notification.count + Rpush::Fcm::Notification.count
    assert_equal %w[pending], @campaign.deliveries.distinct.pluck(:status)
    assert_equal 0, @campaign.reload.queued
  end

  test "finish_if_done moves to sent only when nothing is pending or claimed" do
    d = PushCampaigns::Deliverer.new(@campaign)
    assert_not d.finish_if_done
    with_apps { d.deliver_slice }
    assert d.finish_if_done
    assert_equal "sent", @campaign.reload.status
    assert @campaign.finished_at
  end
end
