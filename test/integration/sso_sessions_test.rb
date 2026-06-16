require "test_helper"

class SsoSessionsTest < ActionDispatch::IntegrationTest
  fixtures :users

  setup do
    @react_app = Doorkeeper::Application.create!(
      name: "React",
      redirect_uri: "urn:ietf:wg:oauth:2.0:oob"
    )
    ENV["REACT_HOST_PROTOCOL"] ||= "https://"
    ENV["REACT_HOST"] ||= "app.example.com"
    ENV["GOOGLE_CLIENT_ID"] ||= "test-google-client-id"
    ENV["GOOGLE_CLIENT_SECRET"] ||= "test-google-client-secret"
    ENV["MICROSOFT_CLIENT_ID"] ||= "test-microsoft-client-id"
    ENV["MICROSOFT_CLIENT_SECRET"] ||= "test-microsoft-client-secret"
    ENV["SERVER_HOST_PROTOCOL"] ||= "https://"
    ENV["SERVER_HOST"] ||= "api.example.com"
    ENV["SSO_AUTHENTICATION_ENDPOINT"] ||= "https://app.example.com/login"
  end

  # --- passthru (POST does not trigger OmniAuth request phase) ---

  test "passthru with google provider returns redirect_url containing google domain" do
    SsoAuthenticationService.stub(:build_auth_url, "https://accounts.google.com/o/oauth2/auth?state=abc") do
      post "/api/v1/identity/sso/auth/google_oauth2"
      assert_response :ok
      json = JSON.parse(response.body)
      assert json["redirect_url"].start_with?("https://accounts.google.com"), "URL should point to Google"
    end
  end

  test "passthru with microsoft provider returns redirect_url" do
    SsoAuthenticationService.stub(:build_auth_url, "https://login.microsoftonline.com/common/oauth2/v2.0/authorize?state=abc") do
      post "/api/v1/identity/sso/auth/microsoft_graph"
      assert_response :ok
      json = JSON.parse(response.body)
      assert json["redirect_url"].start_with?("https://login.microsoftonline.com"), "URL should point to Microsoft"
    end
  end

  test "passthru with invalid provider returns 422" do
    post "/api/v1/identity/sso/auth/invalid_provider"
    assert_response :unprocessable_entity
    json = JSON.parse(response.body)
    assert_equal "Invalid provider", json["error"]
  end

  test "passthru returns JSON with redirect_url key" do
    SsoAuthenticationService.stub(:build_auth_url, "https://accounts.google.com/o/oauth2/auth?state=abc") do
      post "/api/v1/identity/sso/auth/google_oauth2"
      assert_response :ok
      json = JSON.parse(response.body)
      assert json.key?("redirect_url"), "Response should contain redirect_url"
      assert json["redirect_url"].is_a?(String)
    end
  end

  # --- callback: OmniAuth middleware intercepts GET/POST to callback paths ---
  # Testing the callback flow requires OmniAuth test mode, which doesn't work
  # with custom callback_path. Instead, we test the callback via OmniAuth
  # test mode with the default path scheme.

  test "callback GET without valid OAuth code does not return 200" do
    get "/api/v1/identity/sso/auth/google_oauth2/callback"
    # OmniAuth intercepts and triggers failure handler or errors
    assert_not_equal 200, response.status,
      "Callback without valid OAuth exchange should not succeed"
  end

  # --- SSO service logic (find_or_create_from_auth) ---

  test "find_or_create_from_auth creates new user from auth hash" do
    auth = OmniAuth::AuthHash.new(
      provider: "google_oauth2",
      uid: "brand_new_uid",
      info: OmniAuth::AuthHash::InfoHash.new(
        email: "brand_new@example.com",
        name: "Brand New",
        display_name: "Brand New"
      )
    )

    assert_difference "User.count", 1 do
      user = SsoAuthenticationService.find_or_create_from_auth(auth_hash: auth)
      assert_equal "brand_new@example.com", user.email
      assert_equal "google_oauth2", user.provider
      assert_equal "brand_new_uid", user.uid
    end
  end

  test "find_or_create_from_auth with existing user same provider updates uid" do
    oauth_user = users(:oauth_user) # provider: google_oauth2, uid: 123456789
    auth = OmniAuth::AuthHash.new(
      provider: "google_oauth2",
      uid: "updated_uid_999",
      info: OmniAuth::AuthHash::InfoHash.new(
        email: oauth_user.email,
        name: oauth_user.name,
        display_name: oauth_user.name
      )
    )

    assert_no_difference "User.count" do
      user = SsoAuthenticationService.find_or_create_from_auth(auth_hash: auth)
      assert_equal "updated_uid_999", user.uid
      assert_equal "google_oauth2", user.provider
    end
  end

  test "find_or_create_from_auth with existing user DIFFERENT provider raises error" do
    oauth_user = users(:oauth_user) # provider: google_oauth2
    auth = OmniAuth::AuthHash.new(
      provider: "microsoft_graph",
      uid: "ms_uid_999",
      info: OmniAuth::AuthHash::InfoHash.new(
        email: oauth_user.email,
        name: oauth_user.name,
        display_name: oauth_user.name
      )
    )

    error = assert_raises(RuntimeError) do
      SsoAuthenticationService.find_or_create_from_auth(auth_hash: auth)
    end
    assert_includes error.message, "different login method"

    # Provider not overwritten
    oauth_user.reload
    assert_equal "google_oauth2", oauth_user.provider
  end

  # --- State validation ---

  test "valid_state? accepts fresh valid state" do
    state = SsoAuthenticationService.build_state(provider: "google_oauth2")
    assert SsoAuthenticationService.valid_state?(state: state)
  end

  test "valid_state? rejects expired state (>10 min)" do
    payload = { provider: "google_oauth2", ts: (Time.now.to_i - 700) }
    token = Base64.urlsafe_encode64(payload.to_json)
    signature = OpenSSL::HMAC.hexdigest("SHA256", Rails.application.secret_key_base, token)
    expired_state = "#{token}.#{signature}"

    assert_not SsoAuthenticationService.valid_state?(state: expired_state)
  end

  test "valid_state? rejects tampered signature" do
    state = SsoAuthenticationService.build_state(provider: "google_oauth2")
    tampered = state.sub(/.$/, state[-1] == "a" ? "b" : "a")
    assert_not SsoAuthenticationService.valid_state?(state: tampered)
  end

  test "valid_state? rejects blank state" do
    assert_not SsoAuthenticationService.valid_state?(state: nil)
    assert_not SsoAuthenticationService.valid_state?(state: "")
  end

  # --- Token generation ---

  test "generate_sso_access_token creates Doorkeeper token with refresh token" do
    user = users(:admin_user)
    token = TokenServices.generate_sso_access_token(user)

    assert token.token.present?
    assert token.refresh_token.present?
    assert_equal user.id, token.resource_owner_id
  end
end

# Callback flow via OmniAuth test mode (mocked provider exchange).
class SsoCallbackFlowTest < ActionDispatch::IntegrationTest
  fixtures :users

  setup do
    ENV["REACT_HOST_PROTOCOL"] ||= "https://"
    ENV["REACT_HOST"] ||= "app.example.com"
    ENV["SSO_AUTHENTICATION_ENDPOINT"] ||= "https://app.example.com/login"
    @react_host = "#{ENV['REACT_HOST_PROTOCOL']}#{ENV['REACT_HOST']}"

    Doorkeeper::Application.create!(name: "React", redirect_uri: "urn:ietf:wg:oauth:2.0:oob")

    OmniAuth.config.test_mode = true
    OmniAuth.config.mock_auth[:google_oauth2] = OmniAuth::AuthHash.new(
      provider: "google_oauth2",
      uid: "google-uid-123",
      info: { email: "sso-callback@example.com", name: "SSO Callback" }
    )
  end

  teardown do
    OmniAuth.config.test_mode = false
    OmniAuth.config.mock_auth[:google_oauth2] = nil
  end

  def callback(state:)
    get "/api/v1/identity/sso/auth/google_oauth2/callback",
        params: { state: state }, headers: { "Host" => "api.sqd.link" }
  end

  test "callback with valid state creates the user and redirects with tokens" do
    state = SsoAuthenticationService.build_state(provider: "google_oauth2")

    assert_difference "User.count", 1 do
      callback(state: state)
    end

    assert_response :redirect
    location = response.headers["Location"]
    assert location.start_with?(@react_host), "must redirect to the dashboard host, got #{location}"
    assert_match(/token=[^&]+/, location)
    assert_match(/refresh_token=[^&]+/, location)

    user = User.find_by(email: "sso-callback@example.com")
    assert_equal "google-uid-123", user.uid
    token = location[/token=([^&]+)/, 1]
    assert_equal user.id, Doorkeeper::AccessToken.by_token(token).resource_owner_id
  end

  test "callback with invalid state redirects with error and issues no token" do
    assert_no_difference ["User.count", "Doorkeeper::AccessToken.count"] do
      callback(state: "garbage-state")
    end

    assert_response :redirect
    location = response.headers["Location"]
    assert location.start_with?(@react_host)
    assert_match(/error=/, location)
    assert_no_match(/token=/, location.sub(/error=[^&]*/, ""))
  end

  test "callback with expired state redirects with error" do
    payload = { provider: "google_oauth2", ts: (Time.now.to_i - 700) }
    token = Base64.urlsafe_encode64(payload.to_json)
    signature = OpenSSL::HMAC.hexdigest("SHA256", Rails.application.secret_key_base, token)

    callback(state: "#{token}.#{signature}")

    assert_response :redirect
    assert_match(/error=/, response.headers["Location"])
  end

  test "callback for an email registered with password login redirects with error" do
    password_user = users(:admin_user)
    password_user.update_columns(provider: "password", uid: nil)
    OmniAuth.config.mock_auth[:google_oauth2] = OmniAuth::AuthHash.new(
      provider: "google_oauth2",
      uid: "google-uid-999",
      info: { email: password_user.email, name: "Imposter" }
    )
    state = SsoAuthenticationService.build_state(provider: "google_oauth2")

    callback(state: state)

    assert_response :redirect
    location = response.headers["Location"]
    assert_match(/error=/, location)
    assert_match(/different\+login|different%20login/i, location)
    assert_no_match(/refresh_token=/, location)
  end

  test "omniauth_failure redirects to the SSO endpoint" do
    get "/api/v1/identity/sso/auth/failure", headers: { "Host" => "api.sqd.link" }
    assert_response :redirect
    assert_equal ENV["SSO_AUTHENTICATION_ENDPOINT"], response.headers["Location"]
  end
end
