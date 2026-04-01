require "test_helper"

class NotificationMessageSerializerTest < ActiveSupport::TestCase
  fixtures :notification_messages, :notifications, :notification_targets,
           :projects, :instances, :domains, :visitors, :devices

  # ---------------------------------------------------------------------------
  # 1. VALUE VERIFICATION — assert_equal for every own attribute
  # ---------------------------------------------------------------------------

  test "serializes message one with correct own attributes" do
    msg = notification_messages(:one)
    result = NotificationMessageSerializer.serialize(msg)

    assert_equal msg.id, result["id"]
    assert_equal false,  result["read"]
  end

  test "serializes message two with correct own attributes" do
    msg = notification_messages(:two)
    result = NotificationMessageSerializer.serialize(msg)

    assert_equal msg.id, result["id"]
    assert_equal false,  result["read"]
  end

  # ---------------------------------------------------------------------------
  # 2. DELEGATED NOTIFICATION FIELDS — values come from notification, not message
  # ---------------------------------------------------------------------------

  test "title subtitle and auto_display come from notification one" do
    msg = notification_messages(:one)
    result = NotificationMessageSerializer.serialize(msg)

    assert_equal "Welcome",            result["title"]
    assert_equal "Welcome to the app", result["subtitle"]
    assert_equal false,                result["auto_display"]
  end

  test "title subtitle and auto_display come from notification two" do
    msg = notification_messages(:two)
    result = NotificationMessageSerializer.serialize(msg)

    assert_equal "Update Available",   result["title"]
    assert_equal "New features",       result["subtitle"]
    assert_equal true,                 result["auto_display"]
  end

  test "updated_at comes from the notification not the message" do
    msg = notification_messages(:one)
    result = NotificationMessageSerializer.serialize(msg)

    assert_not_nil result["updated_at"], "Expected updated_at to be present"
  end

  test "access_url contains the project domain and notification hashid for both messages" do
    result_one = NotificationMessageSerializer.serialize(notification_messages(:one))
    result_two = NotificationMessageSerializer.serialize(notification_messages(:two))

    assert_not_nil result_one["access_url"]
    assert_not_nil result_two["access_url"]
    assert_match %r{example\.sqd\.link/mm/}, result_one["access_url"]
    assert_match %r{example\.sqd\.link/mm/}, result_two["access_url"]
  end

  # ---------------------------------------------------------------------------
  # 3. EXCLUSION — internal fields must NOT appear
  # ---------------------------------------------------------------------------

  test "excludes created_at visitor_id and notification_id" do
    result = NotificationMessageSerializer.serialize(notification_messages(:one))

    %w[created_at visitor_id notification_id].each do |field|
      assert_not_includes result.keys, field,
        "Expected serialized output to exclude '#{field}'"
    end
  end

  test "top-level keys are exactly the expected set" do
    result = NotificationMessageSerializer.serialize(notification_messages(:one))

    expected_keys = %w[access_url auto_display id read subtitle title updated_at]
    assert_equal expected_keys, result.keys.sort
  end

  # ---------------------------------------------------------------------------
  # 4. NIL HANDLING
  # ---------------------------------------------------------------------------

  test "returns nil for nil input" do
    assert_nil NotificationMessageSerializer.serialize(nil)
  end

  # ---------------------------------------------------------------------------
  # 5. COLLECTION HANDLING
  # ---------------------------------------------------------------------------

  test "serializes a collection with correct size and distinct ids" do
    messages = [notification_messages(:one), notification_messages(:two)]
    result = NotificationMessageSerializer.serialize(messages)

    assert_equal 2, result.size
    assert_equal notification_messages(:one).id, result[0]["id"]
    assert_equal notification_messages(:two).id, result[1]["id"]
  end

  test "collection items have distinct titles from different notifications" do
    messages = [notification_messages(:one), notification_messages(:two)]
    result = NotificationMessageSerializer.serialize(messages)

    assert_equal "Welcome",          result[0]["title"]
    assert_equal "Update Available", result[1]["title"]
  end

  test "auto_display differs between messages linked to different notifications" do
    messages = [notification_messages(:one), notification_messages(:two)]
    result = NotificationMessageSerializer.serialize(messages)

    assert_equal false, result[0]["auto_display"]
    assert_equal true,  result[1]["auto_display"]
  end

  test "serializes empty collection as empty array" do
    result = NotificationMessageSerializer.serialize([])
    assert_equal [], result
  end
end
