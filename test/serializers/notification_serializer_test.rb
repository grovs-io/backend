require "test_helper"

class NotificationSerializerTest < ActiveSupport::TestCase
  fixtures :notifications, :notification_targets, :projects, :instances, :domains

  # ---------------------------------------------------------------------------
  # 1. VALUE VERIFICATION — assert_equal for every attribute
  # ---------------------------------------------------------------------------

  test "serializes notification one with correct attribute values" do
    notification = notifications(:one)
    result = NotificationSerializer.serialize(notification)

    assert_equal notification.id,                result["id"]
    assert_equal "Welcome",                      result["title"]
    assert_equal "Welcome to the app",           result["subtitle"]
    assert_equal "<p>Welcome to our app!</p>",   result["html"]
    assert_equal false,                          result["archived"]
    assert_equal false,                          result["auto_display"]
    assert_equal false,                          result["send_push"]
    assert_includes result.keys, "updated_at"
    assert_not_nil result["updated_at"]
  end

  test "serializes notification two with correct attribute values" do
    notification = notifications(:two)
    result = NotificationSerializer.serialize(notification)

    assert_equal notification.id,                      result["id"]
    assert_equal "Update Available",                   result["title"]
    assert_equal "New features",                       result["subtitle"]
    assert_equal "<p>Check out our new features!</p>", result["html"]
    assert_equal false,                                result["archived"]
    assert_equal true,                                 result["auto_display"]
    assert_equal true,                                 result["send_push"]
    assert_includes result.keys, "updated_at"
    assert_not_nil result["updated_at"]
  end

  # ---------------------------------------------------------------------------
  # 2. NESTED TARGET — verify actual values, not just key presence
  # ---------------------------------------------------------------------------

  test "nested target hash contains correct values for notification one" do
    notification = notifications(:one)
    result = NotificationSerializer.serialize(notification)

    assert_instance_of Hash, result["target"]
    assert_equal notification.notification_target.id, result["target"]["id"]
    assert_equal true,                   result["target"]["existing_users"]
    assert_equal false,                  result["target"]["new_users"]
    assert_equal ["ios", "android"],     result["target"]["platforms"]
  end

  test "nested target hash contains correct values for notification two" do
    notification = notifications(:two)
    result = NotificationSerializer.serialize(notification)

    assert_instance_of Hash, result["target"]
    assert_equal notification.notification_target.id, result["target"]["id"]
    assert_equal false,                  result["target"]["existing_users"]
    assert_equal true,                   result["target"]["new_users"]
    assert_equal ["web"],                result["target"]["platforms"]
  end

  # ---------------------------------------------------------------------------
  # 3. ACCESS_URL — derived from project domain and notification hashid
  # ---------------------------------------------------------------------------

  test "access_url contains the project domain and notification hashid" do
    notification = notifications(:one)
    result = NotificationSerializer.serialize(notification)

    # access_url is computed as "{domain}/mm/{hashid}" — verify the format
    assert_not_nil result["access_url"]
    assert_match %r{example\.sqd\.link/mm/}, result["access_url"]
    assert_includes result["access_url"], notification.hashid
  end

  test "access_url for notification two contains the project domain and hashid" do
    notification = notifications(:two)
    result = NotificationSerializer.serialize(notification)

    # notification two also belongs to project one (same domain)
    assert_not_nil result["access_url"]
    assert_match %r{example\.sqd\.link/mm/}, result["access_url"]
    assert_includes result["access_url"], notification.hashid
  end

  # ---------------------------------------------------------------------------
  # 4. EXCLUSION — internal fields must NOT appear
  # ---------------------------------------------------------------------------

  test "excludes created_at and project_id" do
    result = NotificationSerializer.serialize(notifications(:one))

    %w[created_at project_id].each do |field|
      assert_not_includes result.keys, field,
        "Expected serialized output to exclude '#{field}'"
    end
  end

  test "top-level keys are exactly the expected set" do
    result = NotificationSerializer.serialize(notifications(:one))

    expected_keys = %w[access_url archived auto_display html id send_push subtitle target title updated_at]
    assert_equal expected_keys, result.keys.sort
  end

  # ---------------------------------------------------------------------------
  # 5. NIL HANDLING
  # ---------------------------------------------------------------------------

  test "returns nil for nil input" do
    assert_nil NotificationSerializer.serialize(nil)
  end

  test "target is nil when notification has no notification_target" do
    notification = notifications(:one)
    notification.stub(:notification_target, nil) do
      result = NotificationSerializer.serialize(notification)
      assert_nil result["target"]
    end
  end

  # ---------------------------------------------------------------------------
  # 6. COLLECTION HANDLING
  # ---------------------------------------------------------------------------

  test "serializes a collection with correct size and distinct titles" do
    notif_list = [notifications(:one), notifications(:two)]
    result = NotificationSerializer.serialize(notif_list)

    assert_equal 2, result.size
    assert_equal "Welcome",          result[0]["title"]
    assert_equal "Update Available", result[1]["title"]
  end

  test "collection items have distinct ids" do
    notif_list = [notifications(:one), notifications(:two)]
    result = NotificationSerializer.serialize(notif_list)

    assert_equal notifications(:one).id, result[0]["id"]
    assert_equal notifications(:two).id, result[1]["id"]
  end

  test "auto_display and send_push differ between notifications" do
    notif_list = [notifications(:one), notifications(:two)]
    result = NotificationSerializer.serialize(notif_list)

    assert_equal false, result[0]["auto_display"]
    assert_equal false, result[0]["send_push"]
    assert_equal true,  result[1]["auto_display"]
    assert_equal true,  result[1]["send_push"]
  end

  test "serializes empty collection as empty array" do
    result = NotificationSerializer.serialize([])
    assert_equal [], result
  end
end
