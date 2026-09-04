require "test_helper"

class SsoAuthenticationServiceTest < ActiveSupport::TestCase
  # === find_or_create_from_auth ===

  def mock_auth(provider:, uid:, email:, name:, display_name: nil, email_verified: nil)
    info = OpenStruct.new(display_name: display_name || name, name: name, email: email)
    extra = OpenStruct.new(raw_info: { "xms_edov" => email_verified }.compact)
    OpenStruct.new(provider: provider, uid: uid, info: info, extra: extra)
  end

  # === nOAuth: an unverified email must not take over an existing account ===

  test "a Microsoft login with an unverified email cannot claim an existing password account" do
    email = "victim_#{SecureRandom.hex(4)}@corp.com"
    victim = User.create!(email: email, password: "password123") # no provider (password account)

    # attacker sets their Entra mail to the victim's address; Microsoft does not assert verification
    auth = mock_auth(provider: "microsoft_graph", uid: "attacker-uid", email: email, name: "Attacker")

    assert_raises(RuntimeError) { SsoAuthenticationService.find_or_create_from_auth(auth_hash: auth) }
    assert_nil victim.reload.uid, "the victim account must not be linked to the attacker's IdP identity"
    assert_nil victim.provider
  end

  test "a Microsoft login with a verified email (xms_edov) may link an existing account" do
    email = "verified_#{SecureRandom.hex(4)}@corp.com"
    User.create!(email: email, password: "password123")

    auth = mock_auth(provider: "microsoft_graph", uid: "ms-verified", email: email, name: "Real", email_verified: true)

    user = SsoAuthenticationService.find_or_create_from_auth(auth_hash: auth)
    assert_equal "microsoft_graph", user.reload.provider
    assert_equal "ms-verified", user.uid
  end

  test "a returning SSO user is matched by provider+uid regardless of the email claim" do
    email = "returning_#{SecureRandom.hex(4)}@corp.com"
    u = User.create!(email: email, password: "password123", provider: "microsoft_graph", uid: "stable-uid")

    # even a mismatched/forged email claim resolves to the same account via the stable uid
    auth = mock_auth(provider: "microsoft_graph", uid: "stable-uid", email: "someone-else@evil.com", name: "R")

    assert_equal u.id, SsoAuthenticationService.find_or_create_from_auth(auth_hash: auth).id
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

  test "SSO claim consumes the pending invitation so the invite link cannot be replayed" do
    email = "sso_invite_#{SecureRandom.hex(4)}@test.com"
    invited = User.invite!(email: email) { |u| u.skip_invitation = true }
    assert invited.invitation_token.present?, "precondition: invite is pending"

    auth = mock_auth(provider: "google_oauth2", uid: "inv-claim", email: email, name: "Invited")
    Grovs.stub(:self_hosted?, true) do
      SsoAuthenticationService.find_or_create_from_auth(auth_hash: auth)
    end

    invited.reload
    assert_not_nil invited.invitation_accepted_at, "SSO sign-in must accept the invitation"
    assert_nil invited.invitation_token, "invite token must be cleared, or the link stays replayable"
  end

  test "find_or_create_from_auth canonicalizes the email on the SaaS path too" do
    email = "sso_saas_mixed_#{SecureRandom.hex(4)}@test.com"
    existing = User.create!(email: email, password: "password123")
    auth = mock_auth(provider: "google_oauth2", uid: "saas1", email: email.upcase, name: "SaaS Mixed")

    assert_no_difference "User.count", "mixed case must not create a duplicate on SaaS" do
      assert_equal existing.id, SsoAuthenticationService.find_or_create_from_auth(auth_hash: auth).id
    end
  end

  test "find_or_create_from_auth stores a downcased email for a new SSO user" do
    email = "SSO_New_#{SecureRandom.hex(4)}@Example.COM"
    auth = mock_auth(provider: "google_oauth2", uid: "dc1", email: email, name: "New")

    user = SsoAuthenticationService.find_or_create_from_auth(auth_hash: auth)
    assert_equal email.strip.downcase, user.reload.email
  end

  test "find_or_create_from_auth raises when the IdP supplies no email" do
    auth = mock_auth(provider: "google_oauth2", uid: "noemail", email: nil, name: "No Email")

    assert_no_difference "User.count" do
      error = assert_raises(RuntimeError) { SsoAuthenticationService.find_or_create_from_auth(auth_hash: auth) }
      assert_match(/email address/i, error.message)
    end
  end

  test "find_or_create_from_auth matches an invited user when the IdP returns a mixed-case email" do
    email = "sso_mixed_#{SecureRandom.hex(4)}@test.com"
    invited = User.create!(email: email, password: "password123")
    auth = mock_auth(provider: "google_oauth2", uid: "mx1", email: "  #{email.upcase}  ", name: "Mixed")

    Grovs.stub(:self_hosted?, true) do
      assert_no_difference "User.count" do
        assert_equal invited.id, SsoAuthenticationService.find_or_create_from_auth(auth_hash: auth).id
      end
    end
  end

  test "find_or_create_from_auth blocks a brand-new SSO account when self-hosted" do
    email = "sso_selfhosted_#{SecureRandom.hex(4)}@test.com"
    auth = mock_auth(provider: "google_oauth2", uid: "sh1", email: email, name: "Uninvited")

    Grovs.stub(:self_hosted?, true) do
      assert_no_difference "User.count" do
        error = assert_raises(RuntimeError) do
          SsoAuthenticationService.find_or_create_from_auth(auth_hash: auth)
        end
        assert_match(/invite/i, error.message)
      end
    end
  end

  test "find_or_create_from_auth still lets an invited (existing) user sign in via SSO when self-hosted" do
    email = "sso_invited_#{SecureRandom.hex(4)}@test.com"
    invited = User.create!(email: email, password: "password123")
    auth = mock_auth(provider: "google_oauth2", uid: "inv1", email: email, name: "Invited")

    Grovs.stub(:self_hosted?, true) do
      assert_no_difference "User.count" do
        user = SsoAuthenticationService.find_or_create_from_auth(auth_hash: auth)
        assert_equal invited.id, user.id
        assert_equal "google_oauth2", user.reload.provider
      end
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

  # === provider configuration gating (self-hosted) ===

  SSO_ENV_KEYS = %w[GOOGLE_CLIENT_ID GOOGLE_CLIENT_SECRET
                    MICROSOFT_CLIENT_ID MICROSOFT_CLIENT_SECRET].freeze

  def with_sso_env(**overrides)
    snapshot = SSO_ENV_KEYS.index_with { |k| ENV[k] }
    SSO_ENV_KEYS.each { |k| ENV.delete(k) }
    overrides.each { |k, v| v.nil? ? ENV.delete(k.to_s) : ENV[k.to_s] = v }
    yield
  ensure
    snapshot.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end

  test "provider_configured? is true only when both id and secret are present" do
    with_sso_env(GOOGLE_CLIENT_ID: "id", GOOGLE_CLIENT_SECRET: "secret") do
      assert SsoAuthenticationService.provider_configured?(Grovs::SSO::GOOGLE)
    end
  end

  test "provider_configured? is false when secret is missing" do
    with_sso_env(GOOGLE_CLIENT_ID: "id") do
      assert_not SsoAuthenticationService.provider_configured?(Grovs::SSO::GOOGLE)
    end
  end

  test "provider_configured? is false when id is missing" do
    with_sso_env(GOOGLE_CLIENT_SECRET: "secret") do
      assert_not SsoAuthenticationService.provider_configured?(Grovs::SSO::GOOGLE)
    end
  end

  test "provider_configured? treats blank string as unconfigured" do
    with_sso_env(GOOGLE_CLIENT_ID: "  ", GOOGLE_CLIENT_SECRET: "secret") do
      assert_not SsoAuthenticationService.provider_configured?(Grovs::SSO::GOOGLE)
    end
  end

  test "provider_configured? is false for unknown provider" do
    with_sso_env(GOOGLE_CLIENT_ID: "id", GOOGLE_CLIENT_SECRET: "secret") do
      assert_not SsoAuthenticationService.provider_configured?("okta")
    end
  end

  test "available_providers returns only the configured provider" do
    with_sso_env(GOOGLE_CLIENT_ID: "id", GOOGLE_CLIENT_SECRET: "secret") do
      assert_equal [Grovs::SSO::GOOGLE], SsoAuthenticationService.available_providers
    end
  end

  test "available_providers returns both when both are configured" do
    with_sso_env(GOOGLE_CLIENT_ID: "gid", GOOGLE_CLIENT_SECRET: "gsecret",
                 MICROSOFT_CLIENT_ID: "mid", MICROSOFT_CLIENT_SECRET: "msecret") do
      assert_equal [Grovs::SSO::GOOGLE, Grovs::SSO::MICROSOFT].sort,
                   SsoAuthenticationService.available_providers.sort
    end
  end

  test "available_providers is empty when nothing is configured" do
    with_sso_env do
      assert_empty SsoAuthenticationService.available_providers
    end
  end

  test "sso_enabled? reflects whether any provider is configured" do
    with_sso_env(MICROSOFT_CLIENT_ID: "mid", MICROSOFT_CLIENT_SECRET: "msecret") do
      assert SsoAuthenticationService.sso_enabled?
    end
    with_sso_env do
      assert_not SsoAuthenticationService.sso_enabled?
    end
  end

  test "build_auth_url raises for a provider that is not configured" do
    with_sso_env(GOOGLE_CLIENT_ID: "id", GOOGLE_CLIENT_SECRET: "secret") do
      error = assert_raises(ArgumentError) do
        SsoAuthenticationService.build_auth_url(provider: Grovs::SSO::MICROSOFT)
      end
      assert_match(/not configured/i, error.message)
    end
  end

  test "build_auth_url still raises for an invalid provider" do
    with_sso_env(GOOGLE_CLIENT_ID: "id", GOOGLE_CLIENT_SECRET: "secret") do
      error = assert_raises(ArgumentError) do
        SsoAuthenticationService.build_auth_url(provider: "okta")
      end
      assert_match(/invalid provider/i, error.message)
    end
  end
end
