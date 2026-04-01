require "test_helper"

class NotificationTargetTest < ActiveSupport::TestCase
  fixtures :instances, :projects

  # === validations: platforms ===

  test "valid with a recognized platform in array" do
    notification = Notification.create!(title: "Test", project: projects(:one))

    target = NotificationTarget.new(
      notification: notification,
      platforms: [Grovs::Platforms::IOS],
      new_users: true,
      existing_users: false
    )
    assert target.valid?
  end

  test "invalid with unrecognized platform in array" do
    notification = Notification.create!(title: "Test", project: projects(:one))

    target = NotificationTarget.new(
      notification: notification,
      platforms: ["blackberry"],
      new_users: true,
      existing_users: false
    )
    assert_not target.valid?
    assert_includes target.errors[:platforms], "is not included in the list"
  end

  # === user_targeting_must_have_one_segment ===

  test "invalid when both new_users and existing_users are false" do
    notification = Notification.create!(title: "Test", project: projects(:one))

    target = NotificationTarget.new(
      notification: notification,
      platforms: [Grovs::Platforms::IOS],
      new_users: false,
      existing_users: false
    )
    assert_not target.valid?
    assert_includes target.errors[:fallback], "New and existing can't be both false"
  end

  test "invalid when both new_users and existing_users are true" do
    notification = Notification.create!(title: "Test", project: projects(:one))

    target = NotificationTarget.new(
      notification: notification,
      platforms: [Grovs::Platforms::IOS],
      new_users: true,
      existing_users: true
    )
    assert_not target.valid?
    assert_includes target.errors[:fallback], "New and existing can't be both true"
  end

  test "valid when new_users is true and existing_users is false" do
    notification = Notification.create!(title: "Test", project: projects(:one))

    target = NotificationTarget.new(
      notification: notification,
      platforms: [Grovs::Platforms::IOS],
      new_users: true,
      existing_users: false
    )
    assert target.valid?
  end

  test "valid when new_users is false and existing_users is true" do
    notification = Notification.create!(title: "Test", project: projects(:one))

    target = NotificationTarget.new(
      notification: notification,
      platforms: [Grovs::Platforms::ANDROID],
      new_users: false,
      existing_users: true
    )
    assert target.valid?
  end

  # === serialization ===

  test "serializer excludes created_at, updated_at, and notification_id" do
    notification = Notification.create!(title: "Test", project: projects(:one))

    target = NotificationTarget.create!(
      notification: notification,
      platforms: [Grovs::Platforms::IOS],
      new_users: true,
      existing_users: false
    )

    json = NotificationTargetSerializer.serialize(target)

    assert_not json.key?("created_at")
    assert_not json.key?("updated_at")
    assert_not json.key?("notification_id")
  end
end
