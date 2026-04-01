require "test_helper"

class SsoAuthenticationServiceTest < ActiveSupport::TestCase
  # === find_or_create_from_auth ===

  def mock_auth(provider:, uid:, email:, name:, display_name: nil)
    info = OpenStruct.new(display_name: display_name || name, name: name, email: email)
    OpenStruct.new(provider: provider, uid: uid, info: info)
  end

  test "find_or_create_from_auth creates new user with all fields" do
    email = "sso_new_#{SecureRandom.hex(4)}@test.com"
    auth = mock_auth(provider: "google_oauth2", uid: "g123", email: email, name: "SSO User")

    assert_difference "User.count", 1 do
      user = SsoAuthenticationService.find_or_create_from_auth(auth_hash: auth)
      assert_equal email, user.email
      assert_equal "SSO User", user.name
      assert_equal "google_oauth2", user.provider
      assert_equal "g123", user.uid
      assert user.persisted?
    end
  end

  test "find_or_create_from_auth prefers display_name over name" do
    email = "sso_display_#{SecureRandom.hex(4)}@test.com"
    auth = mock_auth(provider: "google_oauth2", uid: "d1", email: email, name: "Fallback", display_name: "Display Name")

    user = SsoAuthenticationService.find_or_create_from_auth(auth_hash: auth)
    assert_equal "Display Name", user.name
  end

  test "find_or_create_from_auth finds existing user same provider and updates uid" do
    email = "sso_existing_#{SecureRandom.hex(4)}@test.com"
    original = User.create!(email: email, password: "password123", provider: "google_oauth2", uid: "old_uid")

    auth = mock_auth(provider: "google_oauth2", uid: "new_uid", email: email, name: "Updated")

    assert_no_difference "User.count" do
      user = SsoAuthenticationService.find_or_create_from_auth(auth_hash: auth)
      assert_equal original.id, user.id
      assert_equal "new_uid", user.uid
      assert_equal "new_uid", user.reload.uid, "UID should be persisted"
    end
  end

  test "find_or_create_from_auth links provider for user without provider" do
    email = "sso_noprovider_#{SecureRandom.hex(4)}@test.com"
    existing = User.create!(email: email, password: "password123")
    assert_nil existing.provider

    auth = mock_auth(provider: "google_oauth2", uid: "first_uid", email: email, name: "Linked")

    user = SsoAuthenticationService.find_or_create_from_auth(auth_hash: auth)
    assert_equal "google_oauth2", user.provider
    assert_equal "first_uid", user.uid
    assert_equal "google_oauth2", user.reload.provider, "Provider should be persisted"
  end

  test "find_or_create_from_auth raises for user with different provider" do
    email = "sso_diff_#{SecureRandom.hex(4)}@test.com"
    User.create!(email: email, password: "password123", provider: "microsoft_graph", uid: "ms_uid")

    auth = mock_auth(provider: "google_oauth2", uid: "google_uid", email: email, name: "Different")

    error = assert_raises(RuntimeError) do
      SsoAuthenticationService.find_or_create_from_auth(auth_hash: auth)
    end
    assert_match(/different login method/, error.message)
  end

  test "find_or_create_from_auth does not change existing provider" do
    email = "sso_keep_#{SecureRandom.hex(4)}@test.com"
    User.create!(email: email, password: "password123", provider: "google_oauth2", uid: "keep_uid")

    auth = mock_auth(provider: "google_oauth2", uid: "updated_uid", email: email, name: "Keep")

    user = SsoAuthenticationService.find_or_create_from_auth(auth_hash: auth)
    assert_equal "google_oauth2", user.provider, "Provider should remain google_oauth2"
  end

  # === state signing + validation ===

  test "build_state produces token.signature format" do
    state = SsoAuthenticationService.build_state(provider: "google_oauth2")
    parts = state.split(".")
    assert_equal 2, parts.length, "State should have exactly one dot separator"
    assert parts[0].present?, "Token part should not be blank"
    assert parts[1].present?, "Signature part should not be blank"
  end

  test "build_state and valid_state round-trip succeeds" do
    state = SsoAuthenticationService.build_state(provider: "google_oauth2")
    assert SsoAuthenticationService.valid_state?(state: state)
  end

  test "valid_state returns false for tampered signature" do
    state = SsoAuthenticationService.build_state(provider: "google_oauth2")
    token, _sig = state.split(".")
    tampered = "#{token}.#{SecureRandom.hex(32)}"
    assert_not SsoAuthenticationService.valid_state?(state: tampered)
  end

  test "valid_state returns false for tampered payload" do
    state = SsoAuthenticationService.build_state(provider: "google_oauth2")
    _token, sig = state.split(".")
    fake_payload = Base64.urlsafe_encode64({ provider: "hacked", ts: Time.now.to_i }.to_json)
    tampered = "#{fake_payload}.#{sig}"
    assert_not SsoAuthenticationService.valid_state?(state: tampered)
  end

  test "valid_state returns false for expired state" do
    payload = { provider: "google_oauth2", ts: (Time.now.to_i - 700) }
    token = Base64.urlsafe_encode64(payload.to_json)
    signature = OpenSSL::HMAC.hexdigest("SHA256", Rails.application.secret_key_base, token)
    expired_state = "#{token}.#{signature}"

    assert_not SsoAuthenticationService.valid_state?(state: expired_state)
  end

  test "valid_state accepts state just within TTL" do
    payload = { provider: "google_oauth2", ts: (Time.now.to_i - 500) }
    token = Base64.urlsafe_encode64(payload.to_json)
    signature = OpenSSL::HMAC.hexdigest("SHA256", Rails.application.secret_key_base, token)
    valid_state = "#{token}.#{signature}"

    assert SsoAuthenticationService.valid_state?(state: valid_state), "State within 600s TTL should be valid"
  end

  test "valid_state returns false for blank and nil" do
    assert_not SsoAuthenticationService.valid_state?(state: "")
    assert_not SsoAuthenticationService.valid_state?(state: nil)
  end

  test "valid_state returns false for malformed state" do
    assert_not SsoAuthenticationService.valid_state?(state: "no_dot_here")
    assert_not SsoAuthenticationService.valid_state?(state: ".")
    assert_not SsoAuthenticationService.valid_state?(state: ".signature_only")
  end

  # --- New: build_auth_url, find_or_create edge cases ---

  test "build_auth_url raises ArgumentError for unknown provider" do
    assert_raises(ArgumentError) do
      SsoAuthenticationService.build_auth_url(provider: "unknown_provider")
    end
  end

  test "build_auth_url returns URL for google provider" do
    ENV["GOOGLE_CLIENT_ID"] ||= "test-client-id"
    ENV["GOOGLE_CLIENT_SECRET"] ||= "test-client-secret"
    ENV["SERVER_HOST_PROTOCOL"] ||= "https://"
    ENV["SERVER_HOST"] ||= "api.example.com"

    url = SsoAuthenticationService.build_auth_url(provider: Grovs::SSO::GOOGLE)
    assert url.is_a?(String)
    assert_includes url, "accounts.google.com"
  end

  test "build_auth_url returns URL for microsoft provider" do
    ENV["MICROSOFT_CLIENT_ID"] ||= "test-ms-client-id"
    ENV["MICROSOFT_CLIENT_SECRET"] ||= "test-ms-client-secret"
    ENV["SERVER_HOST_PROTOCOL"] ||= "https://"
    ENV["SERVER_HOST"] ||= "api.example.com"

    url = SsoAuthenticationService.build_auth_url(provider: Grovs::SSO::MICROSOFT)
    assert url.is_a?(String)
    assert_includes url, "microsoft"
  end

  test "find_or_create_from_auth handles nil display_name" do
    email = "sso_nil_display_#{SecureRandom.hex(4)}@test.com"
    auth = mock_auth(provider: "google_oauth2", uid: "nd1", email: email, name: "Fallback Name", display_name: nil)

    user = SsoAuthenticationService.find_or_create_from_auth(auth_hash: auth)
    # display_name is nil so it falls through to name
    assert_equal "Fallback Name", user.name
  end

  test "find_or_create_from_auth creates user without usable password" do
    email = "sso_nopass_#{SecureRandom.hex(4)}@test.com"
    auth = mock_auth(provider: "google_oauth2", uid: "np1", email: email, name: "No Pass")

    user = SsoAuthenticationService.find_or_create_from_auth(auth_hash: auth)
    assert user.persisted?
    # SSO user should not be able to authenticate with any password
    assert_not user.valid_password?("password123"), "SSO user should not have a usable password"
    assert_not user.valid_password?(""), "SSO user should not authenticate with empty password"
  end
end
