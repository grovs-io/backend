require "test_helper"
require_relative "auth_test_helper"

class UsersApiTest < ActionDispatch::IntegrationTest
  include AuthTestHelper

  fixtures :instances, :users, :instance_roles, :projects, :domains, :redirect_configs

  setup do
    @admin_user = users(:admin_user)
    @member_user = users(:member_user)
    @headers = doorkeeper_headers_for(@admin_user)
    @client_app = Doorkeeper::Application.create!(
      name: "React",
      redirect_uri: "urn:ietf:wg:oauth:2.0:oob"
    )
  end

  # --- Unauthenticated ---

  test "current_user_details without auth returns 401 with no data" do
    get "#{API_PREFIX}/users/me", headers: api_headers
    assert_response :unauthorized
    assert_no_match(/"user"/, response.body, "401 must not leak user data")
  end

  # --- Create User ---

  test "create user with valid params returns token and persists user" do
    assert_difference "User.count", 1 do
      post "#{API_PREFIX}/users",
        params: { client_id: @client_app.uid, email: "newuser@example.com", password: "password123", name: "New User" },
        headers: api_headers
    end
    assert_response :ok
    json = JSON.parse(response.body)
    assert json["access_token"].present?, "must return access token"
    assert json["refresh_token"].present?, "must return refresh token"
    assert_equal "bearer", json["token_type"]
    assert_equal "New User", json["user"]["name"]
    assert_equal "newuser@example.com", json["user"]["email"]

    created = User.find_by(email: "newuser@example.com")
    assert_not_nil created
    assert_equal "New User", created.name
  end

  test "create user with duplicate email returns conflict and no user created" do
    assert_no_difference "User.count" do
      post "#{API_PREFIX}/users",
        params: { client_id: @client_app.uid, email: @admin_user.email, password: "password123", name: "Dup" },
        headers: api_headers
    end
    assert_response :conflict
    json = JSON.parse(response.body)
    assert json["error"].present?
    assert_not json.key?("access_token"), "conflict must not return token"
  end

  test "create user with invalid client_id returns 403 and no user created" do
    assert_no_difference "User.count" do
      post "#{API_PREFIX}/users",
        params: { client_id: "bad-client-id", email: "test@example.com", password: "pass123", name: "Test" },
        headers: api_headers
    end
    assert_response :forbidden
    json = JSON.parse(response.body)
    assert_equal "Invalid client ID", json["error"]
  end

  # --- Current User Details ---

  test "current_user_details returns correct user data with roles" do
    get "#{API_PREFIX}/users/me", headers: @headers
    assert_response :ok
    json = JSON.parse(response.body)
    assert_equal @admin_user.email, json["user"]["email"]
    assert_equal @admin_user.name, json["user"]["name"]
    assert_kind_of Array, json["user"]["roles"], "must include roles array"
    assert_not json["user"]["roles"].empty?, "admin must have at least one role"
  end

  # --- Edit User ---

  test "edit_user persists name change" do
    patch "#{API_PREFIX}/users/me",
      params: { name: "Updated Name" },
      headers: @headers
    assert_response :ok
    json = JSON.parse(response.body)
    assert_equal "Updated Name", json["user"]["name"]
    assert_kind_of Array, json["user"]["roles"], "edit response must include roles"

    @admin_user.reload
    assert_equal "Updated Name", @admin_user.name, "name must persist in DB"
  end

  # --- Remove User ---

  test "remove_user deletes account and associated roles" do
    headers = doorkeeper_headers_for(@member_user)
    member_role_count = InstanceRole.where(user_id: @member_user.id).count
    assert member_role_count > 0, "precondition: member must have roles"

    assert_difference "User.count", -1 do
      delete "#{API_PREFIX}/users/me", headers: headers
    end
    assert_response :ok
    json = JSON.parse(response.body)
    assert_match(/deleted/i, json["message"])
    assert_nil User.find_by(id: @member_user.id), "user must be deleted from DB"
    assert_equal 0, InstanceRole.where(user_id: @member_user.id).count, "roles must be cleaned up"
  end

  # --- Reset Password ---

  test "reset_password for existing user returns success message" do
    post "#{API_PREFIX}/users/reset_password",
      params: { email: @admin_user.email },
      headers: api_headers
    assert_response :ok
    json = JSON.parse(response.body)
    assert_equal "Email sent", json["message"]
    assert_not json.key?("user"), "reset response must not leak user data"
  end

  test "reset_password for nonexistent user returns 200 to prevent email enumeration" do
    post "#{API_PREFIX}/users/reset_password",
      params: { email: "nobody@example.com" },
      headers: api_headers
    assert_response :ok
    json = JSON.parse(response.body)
    assert_equal "Email sent", json["message"]
  end

  # --- OTP Status ---

  test "otp_status without auth returns 401" do
    post "#{API_PREFIX}/users/otp_status",
      params: { email: @admin_user.email },
      headers: api_headers
    assert_response :unauthorized
  end

  test "otp_enabled returns status for current user only" do
    post "#{API_PREFIX}/users/otp_status",
      headers: @headers
    assert_response :ok
    json = JSON.parse(response.body)
    assert json.key?("otp_enabled"), "must return otp_enabled key"
    assert_equal false, json["otp_enabled"], "OTP must be disabled by default"
  end
end
