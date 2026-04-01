require "test_helper"

class NotificationMessageTest < ActiveSupport::TestCase
  fixtures :instances, :projects, :domains, :devices, :visitors

  # === serialization ===

  test "serializer excludes created_at, visitor_id, notification_id, and updated_at" do
    notification = Notification.create!(
      title: "Test Title",
      subtitle: "Test Subtitle",
      project: projects(:one),
      auto_display: true
    )

    message = NotificationMessage.create!(
      notification: notification,
      visitor: visitors(:ios_visitor)
    )

    json = NotificationMessageSerializer.serialize(message)

    assert_not json.key?("created_at")
    assert_not json.key?("visitor_id")
    assert_not json.key?("notification_id")
    # updated_at is excluded from message but re-added from notification
    assert json.key?("updated_at")
  end

  test "serializer pulls title from associated notification" do
    notification = Notification.create!(
      title: "Important Update",
      subtitle: "Check this out",
      project: projects(:one),
      auto_display: false
    )

    message = NotificationMessage.create!(
      notification: notification,
      visitor: visitors(:ios_visitor)
    )

    json = NotificationMessageSerializer.serialize(message)

    assert_equal "Important Update", json["title"]
    assert_equal "Check this out", json["subtitle"]
    assert_equal false, json["auto_display"]
  end

  test "serializer includes access_url from notification" do
    notification = Notification.create!(
      title: "URL Test",
      project: projects(:one)
    )

    message = NotificationMessage.create!(
      notification: notification,
      visitor: visitors(:ios_visitor)
    )

    json = NotificationMessageSerializer.serialize(message)

    assert json.key?("access_url")
    assert_equal notification.access_url, json["access_url"]
  end

  test "serializer includes updated_at from notification not message" do
    notification = Notification.create!(
      title: "Timestamp Test",
      project: projects(:one)
    )

    message = NotificationMessage.create!(
      notification: notification,
      visitor: visitors(:ios_visitor)
    )

    json = NotificationMessageSerializer.serialize(message)

    assert_equal notification.updated_at.as_json, json["updated_at"]
  end

  test "serializer includes read status" do
    notification = Notification.create!(
      title: "Read Status Test",
      project: projects(:one)
    )

    message = NotificationMessage.create!(
      notification: notification,
      visitor: visitors(:ios_visitor),
      read: false
    )

    json = NotificationMessageSerializer.serialize(message)

    assert_equal false, json["read"]
  end
end
