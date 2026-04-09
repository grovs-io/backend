require "test_helper"

class McpTokenTest < ActiveSupport::TestCase
  fixtures :users

  setup do
    @user = users(:admin_user)
  end

  # --- Token generation and lookup round-trip ---

  test "generate_token produces a token that find_by_plain_token retrieves" do
    token = McpToken.new(user: @user, name: "Round-trip")
    plain = token.generate_token
    token.save!

    found = McpToken.find_by_plain_token(plain) # rubocop:disable Rails/DynamicFindBy
    assert_equal token.id, found.id
    assert_equal @user.id, found.user_id
  end

  test "generate_token stores SHA256 digest, not plaintext" do
    token = McpToken.new(user: @user, name: "Digest check")
    plain = token.generate_token

    expected_digest = Digest::SHA256.hexdigest(plain)
    assert_equal expected_digest, token.token_digest
  end

  # --- Active scope (the real security boundary) ---

  test "find_by_plain_token rejects revoked tokens" do
    token = McpToken.new(user: @user, name: "Revoked")
    plain = token.generate_token
    token.save!
    token.revoke!

    assert_nil McpToken.find_by_plain_token(plain) # rubocop:disable Rails/DynamicFindBy
  end

  test "find_by_plain_token rejects expired tokens" do
    token = McpToken.new(user: @user, name: "Expired")
    plain = token.generate_token
    token.expires_at = 1.second.ago
    token.save!

    assert_nil McpToken.find_by_plain_token(plain) # rubocop:disable Rails/DynamicFindBy
  end

  test "find_by_plain_token handles nil and empty gracefully" do
    # These should not raise — important because Authorization header parsing
    # can yield nil or empty strings.
    assert_nil McpToken.find_by_plain_token(nil) # rubocop:disable Rails/DynamicFindBy
    assert_nil McpToken.find_by_plain_token("") # rubocop:disable Rails/DynamicFindBy
  end

  # --- TTL ---

  test "access token TTL is 1 hour" do
    token = McpToken.new(user: @user, name: "TTL check")
    token.generate_token
    assert_in_delta 1.hour.from_now.to_i, token.expires_at.to_i, 2
  end

  # --- Revoke ---

  test "revoke! sets revoked_at and immediately excludes from active scope" do
    token = McpToken.new(user: @user, name: "Revoke test")
    plain = token.generate_token
    token.save!
    assert_nil token.revoked_at

    token.revoke!
    assert token.revoked_at.present?
    assert_in_delta Time.current.to_i, token.revoked_at.to_i, 2
    # Active scope must exclude it
    assert_nil McpToken.find_by_plain_token(plain) # rubocop:disable Rails/DynamicFindBy
  end

  # --- touch_last_used! ---

  test "touch_last_used! updates timestamp without changing token" do
    token = McpToken.new(user: @user, name: "Touch test")
    token.generate_token
    token.save!
    original_digest = token.token_digest

    assert_nil token.last_used_at
    token.touch_last_used!
    token.reload
    assert token.last_used_at.present?
    assert_equal original_digest, token.token_digest
  end

  # --- Refresh token lifecycle ---

  test "generate_token also produces a refresh token distinct from access token" do
    token = McpToken.new(user: @user, name: "Refresh gen")
    plain_access = token.generate_token
    plain_refresh = token.plain_refresh_token

    assert plain_refresh.present?
    assert token.refresh_token_digest.present?
    assert_not_equal plain_access, plain_refresh, "refresh and access tokens must differ"
    assert_not_equal token.token_digest, token.refresh_token_digest, "digests must differ"
  end

  test "find_by_refresh_token round-trip" do
    token = McpToken.new(user: @user, name: "Refresh lookup")
    token.generate_token
    plain_refresh = token.plain_refresh_token
    token.save!

    found = McpToken.find_by_refresh_token(plain_refresh) # rubocop:disable Rails/DynamicFindBy
    assert_equal token.id, found.id
  end

  test "find_by_refresh_token rejects revoked token" do
    token = McpToken.new(user: @user, name: "Refresh revoked")
    token.generate_token
    plain_refresh = token.plain_refresh_token
    token.save!
    token.revoke!

    assert_nil McpToken.find_by_refresh_token(plain_refresh) # rubocop:disable Rails/DynamicFindBy
  end

end
