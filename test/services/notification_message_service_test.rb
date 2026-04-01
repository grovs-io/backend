require "test_helper"

class NotificationMessageServiceTest < ActiveSupport::TestCase
  fixtures :instances, :projects, :devices, :visitors

  setup do
    @project = projects(:one)
    @ios_visitor = visitors(:ios_visitor)
    @android_visitor = visitors(:android_visitor)

    # Create a web visitor for project :one (no web_visitor fixture available)
    @web_visitor = Visitor.create!(project: @project, device: devices(:web_device), web_visitor: false)

    # Clean slate
    NotificationMessage.delete_all
    Notification.where(project: @project).destroy_all
  end

  # === add_messages_for_new_visitor ===

  test "add_messages_for_new_visitor creates messages for notifications targeting new users" do
    notification = Notification.create!(title: "Welcome", project: @project, archived: false)
    NotificationTarget.create!(notification: notification, new_users: true, existing_users: false)

    assert_difference "NotificationMessage.count", 1 do
      NotificationMessageService.add_messages_for_new_visitor(@ios_visitor)
    end

    message = NotificationMessage.last
    assert_equal notification.id, message.notification_id
    assert_equal @ios_visitor.id, message.visitor_id
  end

  test "add_messages_for_new_visitor does not create messages for archived notifications" do
    notification = Notification.create!(title: "Archived", project: @project, archived: true)
    NotificationTarget.create!(notification: notification, new_users: true, existing_users: false)

    assert_no_difference "NotificationMessage.count" do
      NotificationMessageService.add_messages_for_new_visitor(@ios_visitor)
    end
  end

  test "add_messages_for_new_visitor does not create messages for notifications not targeting new users" do
    notification = Notification.create!(title: "Existing Only", project: @project, archived: false)
    NotificationTarget.create!(notification: notification, new_users: false, existing_users: true)

    assert_no_difference "NotificationMessage.count" do
      NotificationMessageService.add_messages_for_new_visitor(@ios_visitor)
    end
  end

  test "add_messages_for_new_visitor creates messages for multiple matching notifications" do
    n1 = Notification.create!(title: "Notif 1", project: @project, archived: false)
    n2 = Notification.create!(title: "Notif 2", project: @project, archived: false)
    NotificationTarget.create!(notification: n1, new_users: true, existing_users: false)
    NotificationTarget.create!(notification: n2, new_users: true, existing_users: false)

    assert_difference "NotificationMessage.count", 2 do
      NotificationMessageService.add_messages_for_new_visitor(@ios_visitor)
    end
  end

  # === create_notification_messages_for_existing_users ===

  test "create_notification_messages_for_existing_users returns early if target has existing_users false" do
    notification = Notification.create!(title: "New Only", project: @project, archived: false)
    NotificationTarget.create!(notification: notification, new_users: true, existing_users: false)

    assert_no_difference "NotificationMessage.count" do
      NotificationMessageService.create_notification_messages_for_existing_users(notification)
    end
  end

  test "create_notification_messages_for_existing_users returns early if notification already has messages" do
    notification = Notification.create!(title: "Has Messages", project: @project, archived: false)
    NotificationTarget.create!(notification: notification, new_users: false, existing_users: true)
    NotificationMessage.create!(notification: notification, visitor: @ios_visitor)

    assert_no_difference "NotificationMessage.count" do
      NotificationMessageService.create_notification_messages_for_existing_users(notification)
    end
  end

  test "create_notification_messages_for_existing_users with no platform restriction creates messages for all platforms" do
    notification = Notification.create!(title: "All Platforms", project: @project, archived: false, send_push: false)
    NotificationTarget.create!(notification: notification, new_users: false, existing_users: true, platforms: [])

    NotificationMessageService.create_notification_messages_for_existing_users(notification)

    visitor_ids = NotificationMessage.where(notification: notification).pluck(:visitor_id)
    assert_includes visitor_ids, @ios_visitor.id
    assert_includes visitor_ids, @android_visitor.id
    assert_includes visitor_ids, @web_visitor.id
  end

  test "create_notification_messages_for_existing_users with ios platform creates messages only for ios visitors" do
    notification = Notification.create!(title: "iOS Only", project: @project, archived: false, send_push: false)
    NotificationTarget.create!(notification: notification, new_users: false, existing_users: true, platforms: [Grovs::Platforms::IOS])

    NotificationMessageService.create_notification_messages_for_existing_users(notification)

    messages = NotificationMessage.where(notification: notification)
    visitor_ids = messages.pluck(:visitor_id)
    assert_includes visitor_ids, @ios_visitor.id
    assert_not_includes visitor_ids, @android_visitor.id
    assert_not_includes visitor_ids, @web_visitor.id
  end

  test "create_notification_messages_for_existing_users with android platform creates messages only for android visitors" do
    notification = Notification.create!(title: "Android Only", project: @project, archived: false, send_push: false)
    NotificationTarget.create!(notification: notification, new_users: false, existing_users: true, platforms: [Grovs::Platforms::ANDROID])

    NotificationMessageService.create_notification_messages_for_existing_users(notification)

    messages = NotificationMessage.where(notification: notification)
    visitor_ids = messages.pluck(:visitor_id)
    assert_includes visitor_ids, @android_visitor.id
    assert_not_includes visitor_ids, @ios_visitor.id
    assert_not_includes visitor_ids, @web_visitor.id
  end

  # === push notification delivery path ===
  # These tests verify the push path that was previously untested.

  test "create_notification_messages_for_existing_users with send_push true calls RpushService for visitors with push tokens" do
    notification = Notification.create!(title: "Push Test", project: @project, archived: false, send_push: true)
    NotificationTarget.create!(notification: notification, new_users: false, existing_users: true, platforms: [Grovs::Platforms::IOS])

    # Give iOS visitor a push token
    @ios_visitor.device.update_columns(push_token: "ios_push_token_abc")

    rpush_calls = []
    rpush_stub = ->(notif, visitor) { rpush_calls << { notification: notif, visitor: visitor } }

    RpushService.stub(:send_push_for_notification_and_visitor, rpush_stub) do
      Rpush.stub(:push, nil) do
        NotificationMessageService.create_notification_messages_for_existing_users(notification)
      end
    end

    assert_equal 1, rpush_calls.length
    assert_equal notification.id, rpush_calls[0][:notification].id
    assert_equal @ios_visitor.id, rpush_calls[0][:visitor].id
  end

  test "create_notification_messages_for_existing_users with send_push true skips visitors without push tokens" do
    notification = Notification.create!(title: "Push Skip", project: @project, archived: false, send_push: true)
    NotificationTarget.create!(notification: notification, new_users: false, existing_users: true, platforms: [Grovs::Platforms::IOS])

    # ios_visitor has no push_token by default
    assert_nil @ios_visitor.device.push_token

    rpush_calls = []
    rpush_stub = ->(_notif, visitor) { rpush_calls << visitor }

    RpushService.stub(:send_push_for_notification_and_visitor, rpush_stub) do
      Rpush.stub(:push, nil) do
        NotificationMessageService.create_notification_messages_for_existing_users(notification)
      end
    end

    # send_push_to_visitor checks push_token and returns early if nil
    assert_equal 0, rpush_calls.length
  end

  test "create_notification_messages_for_existing_users with send_push false does not call RpushService" do
    notification = Notification.create!(title: "No Push", project: @project, archived: false, send_push: false)
    NotificationTarget.create!(notification: notification, new_users: false, existing_users: true, platforms: [Grovs::Platforms::IOS])

    @ios_visitor.device.update_columns(push_token: "has_a_token")

    rpush_called = false
    RpushService.stub(:send_push_for_notification_and_visitor, ->(_n, _v) { rpush_called = true }) do
      NotificationMessageService.create_notification_messages_for_existing_users(notification)
    end

    assert_not rpush_called, "RpushService should not be called when send_push is false"
  end

  test "create_notification_messages_for_existing_users with send_push true calls Rpush.push after sending" do
    notification = Notification.create!(title: "Rpush Push", project: @project, archived: false, send_push: true)
    NotificationTarget.create!(notification: notification, new_users: false, existing_users: true, platforms: [Grovs::Platforms::IOS])

    @ios_visitor.device.update_columns(push_token: "valid_token")

    rpush_push_called = false

    RpushService.stub(:send_push_for_notification_and_visitor, nil) do
      Rpush.stub(:push, -> { rpush_push_called = true }) do
        NotificationMessageService.create_notification_messages_for_existing_users(notification)
      end
    end

    assert rpush_push_called, "Rpush.push should be called to flush the push queue"
  end

  # === duplicate message behavior ===

  test "create_notification_messages_for_existing_users called twice does not create duplicates due to count guard" do
    notification = Notification.create!(title: "Dedup", project: @project, archived: false, send_push: false)
    NotificationTarget.create!(notification: notification, new_users: false, existing_users: true, platforms: [])

    # First call creates messages
    NotificationMessageService.create_notification_messages_for_existing_users(notification)
    first_count = NotificationMessage.where(notification: notification).count
    assert first_count > 0

    # Second call should return early because notification_messages.count > 0
    assert_no_difference "NotificationMessage.count" do
      NotificationMessageService.create_notification_messages_for_existing_users(notification)
    end
  end

  test "create_notification_messages_for_existing_users returns early when notification has no target" do
    notification = Notification.create!(title: "No Target", project: @project, archived: false)
    # No NotificationTarget created

    assert_no_difference "NotificationMessage.count" do
      NotificationMessageService.create_notification_messages_for_existing_users(notification)
    end
  end

  # === desktop/web platform routing ===

  test "create_notification_messages_for_existing_users with desktop platform creates messages for web visitors" do
    notification = Notification.create!(title: "Desktop", project: @project, archived: false, send_push: false)
    NotificationTarget.create!(notification: notification, new_users: false, existing_users: true, platforms: [Grovs::Platforms::DESKTOP])

    NotificationMessageService.create_notification_messages_for_existing_users(notification)

    visitor_ids = NotificationMessage.where(notification: notification).pluck(:visitor_id)
    # DESKTOP platform routes to WEB visitors in the service
    assert_includes visitor_ids, @web_visitor.id
    assert_not_includes visitor_ids, @ios_visitor.id
    assert_not_includes visitor_ids, @android_visitor.id
  end
end
