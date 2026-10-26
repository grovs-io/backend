require "test_helper"
require "sidekiq/testing"

class RpushAppHistoryPurgeJobTest < ActiveSupport::TestCase
  fixtures :instances, :projects, :devices, :visitors

  def app(name) = Rpush::Fcm::App.create!(name: name, firebase_project_id: "p", json_key: "{}", connections: 1)
  def push(app, **flags) = Rpush::Fcm::Notification.create!(app: app, device_token: "t", notification: { title: "x" }, **flags)

  teardown do
    Rpush::Fcm::Notification.delete_all
    Rpush::Fcm::App.delete_all
  end

  test "removing an app queues the purge of its sent history once the removal commits" do
    removed = app("rotated")
    Sidekiq::Testing.fake! do
      RpushAppHistoryPurgeJob.clear
      RpushService.remove_app(removed)
      assert_equal [[removed.id]], RpushAppHistoryPurgeJob.jobs.map { |j| j["args"] }
    end
  end

  test "the purge deletes only the removed app's sent rows" do
    removed = app("rotated")
    kept = app("live")
    sent = push(removed, delivered: true)
    failed = push(removed, failed: true)
    other = push(kept, delivered: true)
    removed.delete

    Sidekiq::Testing.fake! do
      RpushAppHistoryPurgeJob.clear
      RpushAppHistoryPurgeJob.new.perform(removed.id)
      assert_equal [[removed.id, 2]], RpushAppHistoryPurgeJob.jobs.map { |j| j["args"] }, "runs once more for rows still in flight"
    end

    assert_empty Rpush::Client::ActiveRecord::Notification.where(id: [sent.id, failed.id])
    assert Rpush::Client::ActiveRecord::Notification.exists?(other.id)
  end

  test "an app that still exists is left alone" do
    live = app("live")
    row = push(live, delivered: true)
    RpushAppHistoryPurgeJob.new.perform(live.id)
    assert Rpush::Client::ActiveRecord::Notification.exists?(row.id)
  end

  test "a delivery still queued gets its outcome before its rpush row is deleted" do
    skip "enterprise tree absent" unless defined?(PushDelivery)

    removed = app("rotated")
    sent = push(removed, delivered: true)
    campaign = PushCampaign.create!(project: projects(:one), name: "c", title: "t", body: "b", audience_type: "visitors", recipients: ["x"],
                                    status: "sent")
    row = PushDelivery.create!(push_campaign: campaign, visitor: visitors(:ios_visitor), device_id: devices(:ios_device).id,
                               platform: "ios", status: "queued", rpush_notification_id: sent.id)
    removed.delete

    Sidekiq::Testing.fake! { RpushAppHistoryPurgeJob.new.perform(removed.id) }

    assert_equal "delivered", row.reload.status
    assert_equal 1, campaign.reload.delivered
  end

  test "rows whose outcome can't be recorded are kept, not deleted" do
    removed = app("rotated")
    sent = push(removed, delivered: true)
    removed.delete

    PushOutcomes.stub(:settle, ->(_) { raise ActiveRecord::StatementInvalid, "down" }) do
      assert_raises(ActiveRecord::StatementInvalid) { RpushAppHistoryPurgeJob.new.perform(removed.id) }
    end
    assert Rpush::Client::ActiveRecord::Notification.exists?(sent.id)
  end
end
