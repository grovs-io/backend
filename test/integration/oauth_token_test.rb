require "test_helper"
require_relative "auth_test_helper"

class OauthTokenTest < ActionDispatch::IntegrationTest
  include AuthTestHelper

  fixtures :users

  setup do
    @user = users(:admin_user)
    @password = "SecurePassword123!"
    @user.update!(password: @password, password_confirmation: @password)

    @client_app = Doorkeeper::Application.create!(
      name: "React",
      redirect_uri: "urn:ietf:wg:oauth:2.0:oob"
    )
  end

  test "login without OTP when user has no 2FA returns token" do
    post "/oauth/token", params: {
      grant_type: "password",
      email: @user.email,
      password: @password,
      client_id: @client_app.uid,
      client_secret: @client_app.secret
    }
    assert_response :ok
    json = JSON.parse(response.body)
    assert json["access_token"].present?
    assert json["refresh_token"].present?
  end

  test "login with wrong password returns invalid_grant" do
    post "/oauth/token", params: {
      grant_type: "password",
      email: @user.email,
      password: "WrongPassword!",
      client_id: @client_app.uid,
      client_secret: @client_app.secret
    }
    assert_response :bad_request
    json = JSON.parse(response.body)
    assert_equal "invalid_grant", json["error"]
  end

  test "login with nonexistent email returns invalid_grant" do
    post "/oauth/token", params: {
      grant_type: "password",
      email: "nonexistent@example.com",
      password: @password,
      client_id: @client_app.uid,
      client_secret: @client_app.secret
    }
    assert_response :bad_request
    json = JSON.parse(response.body)
    assert_equal "invalid_grant", json["error"]
  end

  test "login without OTP when user has 2FA returns requires_otp challenge" do
    enable_2fa_for(@user)

    post "/oauth/token", params: {
      grant_type: "password",
      email: @user.email,
      password: @password,
      client_id: @client_app.uid,
      client_secret: @client_app.secret
    }
    assert_response :ok
    json = JSON.parse(response.body)
    assert_equal true, json["requires_otp"]
    assert_nil json["access_token"], "must not issue token without OTP"
  end

  test "login with wrong password when user has 2FA does NOT reveal OTP requirement" do
    enable_2fa_for(@user)

    post "/oauth/token", params: {
      grant_type: "password",
      email: @user.email,
      password: "WrongPassword!",
      client_id: @client_app.uid,
      client_secret: @client_app.secret
    }
    assert_response :bad_request
    json = JSON.parse(response.body)
    assert_equal "invalid_grant", json["error"]
    assert_nil json["requires_otp"], "must not reveal OTP requirement with wrong password"
  end

  test "login with valid OTP when user has 2FA returns token" do
    otp_secret = enable_2fa_for(@user)

    totp = ROTP::TOTP.new(otp_secret)
    otp_code = totp.now

    post "/oauth/token", params: {
      grant_type: "password",
      email: @user.email,
      password: @password,
      otp_code: otp_code,
      client_id: @client_app.uid,
      client_secret: @client_app.secret
    }
    assert_response :ok
    json = JSON.parse(response.body)
    assert json["access_token"].present?
    assert_nil json["requires_otp"]
  end

  test "login with wrong OTP when user has 2FA returns invalid_grant" do
    enable_2fa_for(@user)

    post "/oauth/token", params: {
      grant_type: "password",
      email: @user.email,
      password: @password,
      otp_code: "000000",
      client_id: @client_app.uid,
      client_secret: @client_app.secret
    }
    assert_response :bad_request
    json = JSON.parse(response.body)
    assert_equal "invalid_grant", json["error"]
  end

  # === Refresh token expiry (Doorkeeper grant path) ===

  test "refresh token via oauth/token works within 7 days" do
    # Get initial tokens via password grant
    post "/oauth/token", params: {
      grant_type: "password",
      email: @user.email,
      password: @password,
      client_id: @client_app.uid,
      client_secret: @client_app.secret
    }
    assert_response :ok
    json = JSON.parse(response.body)
    refresh = json["refresh_token"]

    # Refresh within 7 days should work
    post "/oauth/token", params: {
      grant_type: "refresh_token",
      refresh_token: refresh,
      client_id: @client_app.uid,
      client_secret: @client_app.secret
    }
    assert_response :ok
    json = JSON.parse(response.body)
    assert json["access_token"].present?
    assert json["refresh_token"].present?
  end

  test "refresh token via oauth/token rejected after 7 days" do
    # Get initial tokens via password grant
    post "/oauth/token", params: {
      grant_type: "password",
      email: @user.email,
      password: @password,
      client_id: @client_app.uid,
      client_secret: @client_app.secret
    }
    assert_response :ok
    json = JSON.parse(response.body)
    refresh = json["refresh_token"]

    # Find the token and backdate it to 8 days ago
    token = Doorkeeper::AccessToken.by_refresh_token(refresh)
    token.update_column(:created_at, 8.days.ago)

    # Expired refresh token should be rejected
    post "/oauth/token", params: {
      grant_type: "refresh_token",
      refresh_token: refresh,
      client_id: @client_app.uid,
      client_secret: @client_app.secret
    }
    assert_response :bad_request
    json = JSON.parse(response.body)
    assert_equal "invalid_grant", json["error"]
  end

  private

  # Enable 2FA using model setters (not update_columns) so that
  # Active Record encryption is applied to otp_secret.
  # Returns the raw otp_secret for TOTP code generation in tests.
  def enable_2fa_for(user)
    secret = User.generate_otp_secret
    user.otp_secret = secret
    user.otp_required_for_login = true
    user.save!(validate: false)
    secret
  end
end
