require "test_helper"
require_relative "auth_test_helper"

class NotificationsApiTest < ActionDispatch::IntegrationTest
  include AuthTestHelper

  fixtures :instances, :users, :instance_roles, :projects, :domains,
           :redirect_configs, :notifications, :notification_targets

  setup do
    @admin_user = users(:admin_user)
    @project = projects(:one)
    @project_two = projects(:two)
    @notification = notifications(:one)
    @headers = doorkeeper_headers_for(@admin_user)
  end

  # --- Unauthenticated ---

  test "create notification without auth returns 401 with no data" do
    post "#{API_PREFIX}/projects/#{@project.id}/notifications",
      params: { title: "Test", subtitle: "Sub", html: "<p>Hi</p>" },
      headers: api_headers
    assert_response :unauthorized
    assert_no_match(/"notification"/, response.body, "401 must not leak notification data")
  end

  # --- Create Notification ---

  test "create notification persists and returns correct data" do
    assert_difference ["Notification.count", "NotificationTarget.count"], 1 do
      post "#{API_PREFIX}/projects/#{@project.id}/notifications",
        params: { title: "New Notif", subtitle: "New Sub", html: "<p>Body</p>", auto_display: true,
                  new_users: true, existing_users: false, platforms: ["ios"] },
        headers: @headers
    end
    assert_response :ok
    json = JSON.parse(response.body)
    notif = json["notification"]
    assert_equal "New Notif", notif["title"]
    assert_equal "New Sub", notif["subtitle"]
    assert_equal "<p>Body</p>", notif["html"]
    assert notif["auto_display"], "auto_display must be true in response"

    created = Notification.find_by(title: "New Notif")
    assert_not_nil created
    assert_equal @project.id, created.project_id
    assert_not_nil created.notification_target, "must create notification target"
  end

  # --- Search Notifications ---

  test "search notifications returns paginated results with fixture notification" do
    post "#{API_PREFIX}/projects/#{@project.id}/notifications/search",
      params: { archived: "false", page: 1 },
      headers: @headers
    assert_response :ok
    json = JSON.parse(response.body)
    assert_kind_of Array, json["data"], "must return data array"
    assert json.key?("total_entries"), "must return total_entries for pagination"
    assert json.key?("page"), "must return page for pagination"
    assert_kind_of Integer, json["total_entries"], "total_entries must be an integer"

    titles = json["data"].map { |n| n["title"] }
    assert_includes titles, @notification.title, "fixture notification must appear in results"
  end

  # --- Archive Notification ---

  test "archive notification sets archived flag in DB and returns updated list" do
    # notification :two targets new_users only (existing_users: false), so it can be archived
    archivable = notifications(:two)
    assert_not archivable.archived, "precondition: notification must not be archived"

    delete "#{API_PREFIX}/projects/#{@project.id}/notifications/#{archivable.id}",
      headers: @headers
    assert_response :ok

    archivable.reload
    assert archivable.archived, "notification must be archived in DB"
  end

  test "archive notification targeting existing users returns 422" do
    # notification :one targets existing_users: true — cannot be archived
    delete "#{API_PREFIX}/projects/#{@project.id}/notifications/#{@notification.id}",
      headers: @headers
    assert_response :unprocessable_entity
    json = JSON.parse(response.body)
    assert_match(/can't archive/i, json["error"], "must explain why archival is blocked")

    @notification.reload
    assert_not @notification.archived, "notification must remain unarchived in DB"
  end

  # --- Nonexistent Notification ---

  test "archive nonexistent notification returns 404 with no data leak" do
    delete "#{API_PREFIX}/projects/#{@project.id}/notifications/999999999",
      headers: @headers
    assert_response :not_found
    json = JSON.parse(response.body)
    assert json.key?("error"), "404 must include error message"
    assert_no_match(/"notification"/, response.body, "404 must not leak notification data")
  end

  # --- Missing Required Search Params ---

  test "search without archived param returns 400" do
    post "#{API_PREFIX}/projects/#{@project.id}/notifications/search",
      params: { page: 1 },
      headers: @headers
    assert_response :bad_request
  end

  # --- Empty Search Results ---

  test "search with archived true returns empty array when no archived notifications" do
    post "#{API_PREFIX}/projects/#{@project.id}/notifications/search",
      params: { archived: "true", page: 1 },
      headers: @headers
    assert_response :ok
    json = JSON.parse(response.body)
    assert_kind_of Array, json["data"], "must return data array"
    assert_equal 0, json["data"].size, "no archived notifications in fixtures"
    assert json.key?("total_entries"), "must include pagination meta"
  end

  # --- Create with Minimal Params ---

  test "create notification with minimal params applies defaults" do
    assert_difference "Notification.count", 1 do
      post "#{API_PREFIX}/projects/#{@project.id}/notifications",
        params: { title: "Minimal", html: "<p>Just body</p>", platforms: ["ios"], new_users: true },
        headers: @headers
    end
    assert_response :ok
    json = JSON.parse(response.body)
    notif = json["notification"]
    assert_equal "Minimal", notif["title"]
    assert_equal "<p>Just body</p>", notif["html"]

    created = Notification.find_by(title: "Minimal")
    assert_not_nil created
    assert_equal false, created.auto_display, "auto_display must default to false"
    assert_equal false, created.send_push, "send_push must default to false"
  end

  # --- Cross-Tenant ---

  test "access another instance project notifications returns 403 with no data leak" do
    post "#{API_PREFIX}/projects/#{@project_two.id}/notifications/search",
      params: { archived: "false", page: 1 },
      headers: @headers
    assert_response :forbidden
    json = JSON.parse(response.body)
    assert_equal "Forbidden", json["error"]
    assert_not json.key?("data"), "403 must not leak notification data"
    assert_not json.key?("notifications"), "403 must not leak notification data"
  end
end
