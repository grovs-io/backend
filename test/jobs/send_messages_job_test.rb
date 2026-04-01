require "test_helper"

class SendMessagesJobTest < ActiveSupport::TestCase
  fixtures :instances, :projects, :notifications, :notification_targets, :devices, :visitors

  setup do
    @job = SendMessagesJob.new
    @project = projects(:one)
  end

  # --- Real NotificationMessageService integration ---

  test "creates NotificationMessage for each visitor on matching platform" do
    notification = Notification.create!(project: @project, title: "Real Notif", send_push: false)
    NotificationTarget.create!(notification: notification, existing_users: true, platforms: [])

    # ios_visitor and android_visitor are on project :one
    # With empty platforms array, it creates for iOS, Android, and Web
    Rpush.stub(:push, -> { nil }) do
      @job.perform(notification.id)
    end

    messages = NotificationMessage.where(notification_id: notification.id)
    assert messages.count >= 2, "Should create messages for ios_visitor and android_visitor (got #{messages.count})"

    visitor_ids = messages.pluck(:visitor_id)
    assert_includes visitor_ids, visitors(:ios_visitor).id, "Should create message for iOS visitor"
    assert_includes visitor_ids, visitors(:android_visitor).id, "Should create message for Android visitor"
  end

  test "respects platform filtering — iOS only creates messages for iOS visitors only" do
    notification = Notification.create!(project: @project, title: "iOS Only", send_push: false)
    NotificationTarget.create!(notification: notification, existing_users: true, platforms: ["ios"])

    Rpush.stub(:push, -> { nil }) do
      @job.perform(notification.id)
    end

    messages = NotificationMessage.where(notification_id: notification.id)
    visitor_ids = messages.pluck(:visitor_id)
    assert_includes visitor_ids, visitors(:ios_visitor).id, "Should include iOS visitor"
    assert_not_includes visitor_ids, visitors(:android_visitor).id, "Should NOT include Android visitor"
  end

  test "idempotent — calling twice does not double-create messages" do
    notification = Notification.create!(project: @project, title: "Idempotent", send_push: false)
    NotificationTarget.create!(notification: notification, existing_users: true, platforms: [])

    Rpush.stub(:push, -> { nil }) do
      @job.perform(notification.id)
      first_count = NotificationMessage.where(notification_id: notification.id).count

      @job.perform(notification.id)
      second_count = NotificationMessage.where(notification_id: notification.id).count

      assert_equal first_count, second_count, "Second call should not create more messages"
    end
  end

  test "skips when notification_target has existing_users false" do
    notification = Notification.create!(project: @project, title: "No Target", send_push: false)
    NotificationTarget.create!(notification: notification, existing_users: false, new_users: true, platforms: [])

    assert_no_difference "NotificationMessage.count" do
      @job.perform(notification.id)
    end
  end

  test "skips when notification has no notification_target" do
    notification = Notification.create!(project: @project, title: "No Target At All", send_push: false)
    # No NotificationTarget created

    assert_no_difference "NotificationMessage.count" do
      @job.perform(notification.id)
    end
  end

  test "returns early for nonexistent notification — no messages created" do
    assert_no_difference "NotificationMessage.count" do
      @job.perform(999999)
    end
  end
end
