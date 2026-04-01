require "test_helper"
require_relative "auth_test_helper"

class SdkNotificationsTest < ActionDispatch::IntegrationTest
  include AuthTestHelper

  fixtures :instances, :projects, :applications, :ios_configurations,
           :android_configurations, :devices, :visitors, :domains,
           :redirect_configs, :notifications, :notification_messages,
           :notification_targets

  setup do
    @project = projects(:one)
    @visitor = visitors(:ios_visitor)
    @notification_message = notification_messages(:one)
    @headers = sdk_headers_for(@project, @visitor, platform: "ios")
  end

  # --- Unauthenticated ---

  test "notifications for device without SDK headers returns 403 with no data" do
    post "#{SDK_PREFIX}/notifications_for_device",
      params: { page: 1 },
      headers: { "Host" => sdk_host }
    assert_response :forbidden
    json = JSON.parse(response.body)
    assert_not json.key?("notifications"), "403 must not leak notification data"
  end

  # --- List Notifications ---

  test "notifications for device returns notification array with expected structure" do
    post "#{SDK_PREFIX}/notifications_for_device",
      params: { page: 1 },
      headers: @headers
    assert_response :ok
    json = JSON.parse(response.body)
    assert_kind_of Array, json["notifications"], "must return notifications array"

    if json["notifications"].any?
      notif = json["notifications"].first
      %w[id title subtitle read auto_display].each do |key|
        assert notif.key?(key), "notification must include #{key}"
      end
    end
  end

  # --- Unread Count ---

  test "unread notifications count returns correct number" do
    unread_count = @visitor.notification_messages.where(read: false).count
    get "#{SDK_PREFIX}/number_of_unread_notifications", headers: @headers
    assert_response :ok
    json = JSON.parse(response.body)
    assert_equal unread_count, json["number_of_unread_notifications"],
      "must return correct unread count matching DB"
  end

  # --- Mark as Read ---

  test "mark notification as read persists in DB" do
    assert_not @notification_message.read, "precondition: notification must be unread"

    post "#{SDK_PREFIX}/mark_notification_as_read",
      params: { id: @notification_message.id },
      headers: @headers
    assert_response :ok
    json = JSON.parse(response.body)
    assert_equal "Marked as read", json["message"]

    @notification_message.reload
    assert @notification_message.read, "notification must be marked as read in DB"
  end

  test "mark nonexistent notification as read returns 404 with error" do
    post "#{SDK_PREFIX}/mark_notification_as_read",
      params: { id: 999999 },
      headers: @headers
    assert_response :not_found
    json = JSON.parse(response.body)
    assert_equal "Notification not found", json["error"]
  end

  # --- Auto Display Notifications ---

  test "auto display notifications returns only auto_display notifications" do
    get "#{SDK_PREFIX}/notifications_to_display_automatically", headers: @headers
    assert_response :ok
    json = JSON.parse(response.body)
    assert_kind_of Array, json["notifications"], "must return notifications array"

    # Every returned notification must have auto_display: true
    json["notifications"].each do |notif|
      assert notif["auto_display"], "returned notification '#{notif['title']}' must have auto_display=true"
    end
  end
end
