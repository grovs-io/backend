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

class UsersAccountFlowsTest < ActionDispatch::IntegrationTest
  include AuthTestHelper

  fixtures :instances, :users, :instance_roles, :projects, :domains, :redirect_configs

  setup do
    @admin_user = users(:admin_user)
    @headers = doorkeeper_headers_for(@admin_user)
    @client_app = Doorkeeper::Application.create!(
      name: "React",
      redirect_uri: "urn:ietf:wg:oauth:2.0:oob"
    )
  end

  # --- change_password ---

  test "change_password with valid reset token updates the password" do
    raw_token = @admin_user.send_reset_password_instructions

    post "#{API_PREFIX}/users/change_password",
      params: { reset_token: raw_token, new_password: "brand-new-pass-123" },
      headers: api_headers
    assert_response :ok

    assert @admin_user.reload.valid_password?("brand-new-pass-123"),
      "new password must be set"
  end

  test "change_password with invalid token returns 404 and keeps the old password" do
    digest_before = @admin_user.encrypted_password

    post "#{API_PREFIX}/users/change_password",
      params: { reset_token: "not-a-real-token", new_password: "whatever-123" },
      headers: api_headers
    assert_response :not_found
    assert_equal digest_before, @admin_user.reload.encrypted_password,
      "password digest must be untouched"
  end

  # --- accept_invite ---

  test "accept_invite with valid token activates the account and returns auth token" do
    invited = User.invite!(email: "invited@example.com", skip_invitation: true)

    post "#{API_PREFIX}/users/accept_invite",
      params: { invitation_token: invited.raw_invitation_token,
                password: "invited-pass-123", name: "Invited Person",
                client_id: @client_app.uid },
      headers: api_headers

    assert_response :ok
    json = JSON.parse(response.body)
    assert json["access_token"].present?, "must return an access token"
    assert json["refresh_token"].present?, "must return a refresh token"
    assert_equal "bearer", json["token_type"]
    assert json["expires_in"].is_a?(Integer)
    assert json["created_at"].is_a?(Integer)
    assert_equal "invited@example.com", json.dig("user", "email")
    token = Doorkeeper::AccessToken.by_token(json["access_token"])
    assert_equal User.find_by(email: "invited@example.com").id, token.resource_owner_id,
      "token must belong to the invited user"

    invited.reload
    assert invited.invitation_accepted_at.present?, "invitation must be accepted"
    assert_equal "Invited Person", invited.name
    assert invited.valid_password?("invited-pass-123")
  end

  test "accept_invite with bad invitation token returns 422" do
    post "#{API_PREFIX}/users/accept_invite",
      params: { invitation_token: "bogus", password: "x-pass-123",
                name: "X", client_id: @client_app.uid },
      headers: api_headers
    assert_response :unprocessable_entity
  end

  test "accept_invite with unknown client_id returns 403" do
    invited = User.invite!(email: "invited2@example.com", skip_invitation: true)

    post "#{API_PREFIX}/users/accept_invite",
      params: { invitation_token: invited.raw_invitation_token,
                password: "x-pass-123", name: "X", client_id: "nope" },
      headers: api_headers
    assert_response :forbidden
    assert invited.reload.invitation_accepted_at.nil?, "invite must not be consumed"
  end

  # --- otp_qr / set_2fa_enabled ---

  test "otp_qr provisions a TOTP secret and returns an SVG QR code" do
    @admin_user.update_columns(otp_secret: nil, otp_required_for_login: false)

    get "#{API_PREFIX}/users/me/otp_qr", headers: @headers
    assert_response :ok
    assert_includes response.body, "<svg"
    assert UserAccountService.valid_otp_secret?(@admin_user.reload.otp_secret),
      "a Base32 OTP secret must be persisted"
  end

  test "set_2fa_enabled with correct OTP code enables 2FA" do
    get "#{API_PREFIX}/users/me/otp_qr", headers: @headers
    @admin_user.reload
    code = @admin_user.current_otp

    put "#{API_PREFIX}/users/me/two_factor",
      params: { enable_2fa: true, otp_code: code }, headers: @headers

    assert_response :ok
    assert @admin_user.reload.otp_required_for_login, "2FA must be enabled"
  end

  test "set_2fa_enabled with wrong OTP code returns 403 and leaves 2FA off" do
    get "#{API_PREFIX}/users/me/otp_qr", headers: @headers
    @admin_user.reload
    @admin_user.update_columns(otp_required_for_login: false)

    put "#{API_PREFIX}/users/me/two_factor",
      params: { enable_2fa: true, otp_code: "000000" }, headers: @headers

    assert_response :forbidden
    assert_not @admin_user.reload.otp_required_for_login, "2FA must stay disabled"
  end

  test "set_2fa_enabled requires authentication" do
    put "#{API_PREFIX}/users/me/two_factor",
      params: { enable_2fa: true, otp_code: "123456" }, headers: api_headers
    assert_response :unauthorized
  end
end
