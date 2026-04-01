require "test_helper"

class TokenServicesTest < ActiveSupport::TestCase
  fixtures :users

  setup do
    @user = users(:admin_user)
    @app = Doorkeeper::Application.create!(name: "React", redirect_uri: "urn:ietf:wg:oauth:2.0:oob")
  end

  # === generate_refresh_token ===

  test "generate_refresh_token returns a 64-char hex string" do
    token = TokenServices.generate_refresh_token
    assert_equal 64, token.length
    assert_match(/\A[0-9a-f]{64}\z/, token)
  end

  # === generate_sso_access_token ===

  test "generate_sso_access_token creates an access token for the user" do
    assert_difference "Doorkeeper::AccessToken.count", 1 do
      TokenServices.generate_sso_access_token(@user)
    end
  end

  test "generate_sso_access_token token has correct resource_owner_id refresh_token and expires_in" do
    access_token = TokenServices.generate_sso_access_token(@user)

    assert_equal @user.id, access_token.resource_owner_id
    assert access_token.refresh_token.present?, "Token should have a refresh_token"
    assert_equal Doorkeeper.configuration.access_token_expires_in.to_i, access_token.expires_in
  end

  # === revoke_user_access_token ===

  test "revoke_user_access_token revokes the token from the Authorization header" do
    access_token = TokenServices.generate_sso_access_token(@user)
    # With hash_token_secrets enabled, find_by(token:) matches on the hashed value
    token_value = access_token.token

    request = OpenStruct.new(headers: { "Authorization" => "Bearer #{token_value}" })
    TokenServices.revoke_user_access_token(request)

    access_token.reload
    assert access_token.revoked?, "Token should be revoked"
  end

  test "revoke_user_access_token does nothing when no Authorization header present" do
    access_token = TokenServices.generate_sso_access_token(@user)

    request = OpenStruct.new(headers: {})
    TokenServices.revoke_user_access_token(request)

    access_token.reload
    assert_not access_token.revoked?, "Token should not be revoked"
  end

  test "revoke_user_access_token does nothing when token already revoked" do
    access_token = TokenServices.generate_sso_access_token(@user)
    token_value = access_token.token
    access_token.revoke

    request = OpenStruct.new(headers: { "Authorization" => "Bearer #{token_value}" })

    assert_nothing_raised do
      TokenServices.revoke_user_access_token(request)
    end

    access_token.reload
    assert access_token.revoked?, "Token should remain revoked"
  end

  # === refresh_user_access_token ===

  test "refresh_user_access_token revokes old token and returns new one" do
    old_token = TokenServices.generate_sso_access_token(@user)
    # refresh_token is stored as plain text (from generate_refresh_token)
    old_refresh = old_token.refresh_token

    new_token = TokenServices.refresh_user_access_token(old_refresh)

    assert new_token.present?, "Should return a new access token"
    assert_not_equal old_token.id, new_token.id, "Should be a different token record"
    assert_equal @user.id, new_token.resource_owner_id

    old_token.reload
    assert old_token.revoked?, "Old token should be revoked"
  end

  test "refresh_user_access_token returns nil for revoked refresh token" do
    access_token = TokenServices.generate_sso_access_token(@user)
    refresh = access_token.refresh_token
    access_token.revoke

    result = TokenServices.refresh_user_access_token(refresh)
    assert_nil result
  end

  test "refresh_user_access_token returns nil for non-existent refresh token" do
    result = TokenServices.refresh_user_access_token("nonexistent_token_value")
    assert_nil result
  end

  test "refresh_user_access_token returns nil for expired refresh token (older than 7 days)" do
    access_token = TokenServices.generate_sso_access_token(@user)
    refresh = access_token.refresh_token

    # Backdate token to 8 days ago
    access_token.update_column(:created_at, 8.days.ago)

    result = TokenServices.refresh_user_access_token(refresh)
    assert_nil result, "Expired refresh token should be rejected"

    access_token.reload
    assert_not access_token.revoked?, "Expired token should not be revoked (just rejected)"
  end

  test "refresh_user_access_token works for refresh token under 7 days old" do
    access_token = TokenServices.generate_sso_access_token(@user)
    refresh = access_token.refresh_token

    # Backdate token to 6 days ago (still valid)
    access_token.update_column(:created_at, 6.days.ago)

    new_token = TokenServices.refresh_user_access_token(refresh)
    assert new_token.present?, "Non-expired refresh token should work"
    assert_equal @user.id, new_token.resource_owner_id
  end

  # === hash_token_secrets regression (dfd562f) ===
  # When hash_token_secrets drops the fallback: :plain option, Doorkeeper
  # stores SHA-256 hashes in the DB. Raw find_by(refresh_token: plain)
  # will never match. These tests simulate that by manually hashing the
  # stored values, proving by_token/by_refresh_token still work.

  test "refresh works when DB stores SHA-256 hashed refresh_token" do
    access_token = TokenServices.generate_sso_access_token(@user)
    plain_refresh = access_token.refresh_token

    # Simulate hash_token_secrets without fallback: hash the DB value
    hashed = Digest::SHA256.hexdigest(plain_refresh)
    ActiveRecord::Base.connection.execute(
      "UPDATE oauth_access_tokens SET refresh_token = '#{hashed}' WHERE id = #{access_token.id}"
    )

    new_token = TokenServices.refresh_user_access_token(plain_refresh)
    assert new_token.present?,
      "Refresh with plain-text token must succeed against hashed DB value"

    access_token.reload
    assert access_token.revoked?, "Old token should be revoked"
  end

  test "revoke works when DB stores SHA-256 hashed access token" do
    access_token = TokenServices.generate_sso_access_token(@user)
    plain_token = access_token.token

    # Simulate hash_token_secrets without fallback: hash the DB value
    hashed = Digest::SHA256.hexdigest(plain_token)
    ActiveRecord::Base.connection.execute(
      "UPDATE oauth_access_tokens SET token = '#{hashed}' WHERE id = #{access_token.id}"
    )

    request = OpenStruct.new(headers: { "Authorization" => "Bearer #{plain_token}" })
    TokenServices.revoke_user_access_token(request)

    access_token.reload
    assert access_token.revoked?,
      "Revoke with plain-text token must succeed against hashed DB value"
  end
end
