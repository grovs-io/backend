require "test_helper"

class SsoTokensTest < ActionDispatch::IntegrationTest
  fixtures :users

  setup do
    @react_app = Doorkeeper::Application.create!(
      name: "React",
      redirect_uri: "urn:ietf:wg:oauth:2.0:oob"
    )
    @user = users(:admin_user)
  end

  test "valid refresh token returns new token pair" do
    access_token = TokenServices.generate_sso_access_token(@user)
    original_refresh = access_token.refresh_token

    post "/api/v1/identity/sso/tokens/refresh",
      params: { refresh_token: original_refresh }
    assert_response :ok
    json = JSON.parse(response.body)
    assert json["token"].present?, "Response should include a new access token"
    assert json["refresh_token"].present?, "Response should include a new refresh token"
    assert_not_equal original_refresh, json["refresh_token"], "New refresh token should differ from old one"
  end

  test "valid refresh revokes the old token" do
    access_token = TokenServices.generate_sso_access_token(@user)
    original_refresh = access_token.refresh_token

    post "/api/v1/identity/sso/tokens/refresh",
      params: { refresh_token: original_refresh }
    assert_response :ok

    # Old token should now be revoked — replay should fail
    post "/api/v1/identity/sso/tokens/refresh",
      params: { refresh_token: original_refresh }
    assert_response :unauthorized
  end

  test "revoked refresh token returns 401" do
    access_token = TokenServices.generate_sso_access_token(@user)
    access_token.revoke

    post "/api/v1/identity/sso/tokens/refresh",
      params: { refresh_token: access_token.refresh_token }
    assert_response :unauthorized
    json = JSON.parse(response.body)
    assert_equal "Token not valid", json["error"]
  end

  test "nonexistent refresh token returns 401" do
    post "/api/v1/identity/sso/tokens/refresh",
      params: { refresh_token: "nonexistent_token_abc123" }
    assert_response :unauthorized
  end

  test "missing refresh_token param returns 400" do
    post "/api/v1/identity/sso/tokens/refresh", params: {}
    # params.require(:refresh_token) raises ParameterMissing → 400
    assert_response :bad_request
  end

  test "expired refresh token (older than 7 days) returns 401" do
    access_token = TokenServices.generate_sso_access_token(@user)
    refresh = access_token.refresh_token

    access_token.update_column(:created_at, 8.days.ago)

    post "/api/v1/identity/sso/tokens/refresh",
      params: { refresh_token: refresh }
    assert_response :unauthorized
    json = JSON.parse(response.body)
    assert_equal "Token not valid", json["error"]
  end
end
