require "test_helper"

class McpAuthorizationCodeTest < ActiveSupport::TestCase
  fixtures :users

  setup do
    @user = users(:admin_user)
  end

  # --- Generation ---

  test "generate_for creates a code with 60-second TTL" do
    code = McpAuthorizationCode.generate_for(
      user: @user,
      redirect_uri: "http://localhost:3456/callback",
      client_id: "test-client"
    )

    assert code.persisted?
    assert code.code.present?
    assert code.expires_at > Time.current
    assert code.expires_at <= 61.seconds.from_now, "TTL must be ~60 seconds, not longer"
  end

  test "generate_for stores PKCE and OAuth fields" do
    code = McpAuthorizationCode.generate_for(
      user: @user,
      redirect_uri: "http://localhost:3456/callback",
      client_id: "my-client",
      code_challenge: "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM",
      code_challenge_method: "S256",
      state: "random-state-123",
      scope: "mcp:full"
    )

    assert_equal "my-client", code.client_id
    assert_equal "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM", code.code_challenge
    assert_equal "S256", code.code_challenge_method
    assert_equal "random-state-123", code.state
    assert_equal "mcp:full", code.scope
  end

  # --- Exchange: the real security-critical method ---

  test "exchange returns the authorization code record and marks it used" do
    code = McpAuthorizationCode.generate_for(
      user: @user,
      redirect_uri: "http://localhost:3456/callback",
      client_id: "test-client"
    )

    result = McpAuthorizationCode.exchange(
      code: code.code,
      redirect_uri: "http://localhost:3456/callback",
      client_id: "test-client"
    )

    assert result.is_a?(McpAuthorizationCode)
    assert_equal @user.id, result.user_id
    assert code.reload.used_at.present?, "must be marked as used"
  end

  test "exchange enforces redirect_uri match" do
    code = McpAuthorizationCode.generate_for(
      user: @user,
      redirect_uri: "http://localhost:3456/callback",
      client_id: "test-client"
    )

    result = McpAuthorizationCode.exchange(
      code: code.code,
      redirect_uri: "http://localhost:9999/wrong",
      client_id: "test-client"
    )
    assert_nil result, "wrong redirect_uri must be rejected"
    assert_nil code.reload.used_at, "must NOT be marked used on failed exchange"
  end

  test "exchange enforces client_id match" do
    code = McpAuthorizationCode.generate_for(
      user: @user,
      redirect_uri: "http://localhost:3456/callback",
      client_id: "correct-client"
    )

    result = McpAuthorizationCode.exchange(
      code: code.code,
      redirect_uri: "http://localhost:3456/callback",
      client_id: "wrong-client"
    )
    assert_nil result, "wrong client_id must be rejected"
  end

  test "exchange rejects already-used code (single-use enforcement)" do
    code = McpAuthorizationCode.generate_for(
      user: @user,
      redirect_uri: "http://localhost:3456/callback",
      client_id: "test-client"
    )

    first = McpAuthorizationCode.exchange(
      code: code.code,
      redirect_uri: "http://localhost:3456/callback",
      client_id: "test-client"
    )
    assert first.present?, "first exchange should succeed"

    second = McpAuthorizationCode.exchange(
      code: code.code,
      redirect_uri: "http://localhost:3456/callback",
      client_id: "test-client"
    )
    assert_nil second, "second exchange must fail — codes are single-use"
  end

  test "exchange rejects expired code" do
    code = McpAuthorizationCode.generate_for(
      user: @user,
      redirect_uri: "http://localhost:3456/callback",
      client_id: "test-client"
    )

    travel_to 2.minutes.from_now do
      result = McpAuthorizationCode.exchange(
        code: code.code,
        redirect_uri: "http://localhost:3456/callback",
        client_id: "test-client"
      )
      assert_nil result, "expired codes must be rejected"
    end
  end

  test "exchange returns nil for nonexistent code" do
    result = McpAuthorizationCode.exchange(
      code: "does-not-exist",
      redirect_uri: "http://localhost:3456/callback",
      client_id: "test-client"
    )
    assert_nil result
  end

  test "exchange returns record with PKCE fields for downstream verification" do
    code = McpAuthorizationCode.generate_for(
      user: @user,
      redirect_uri: "http://localhost:3456/callback",
      client_id: "test-client",
      code_challenge: "test-challenge-value",
      code_challenge_method: "S256"
    )

    result = McpAuthorizationCode.exchange(
      code: code.code,
      redirect_uri: "http://localhost:3456/callback",
      client_id: "test-client"
    )

    assert_equal "test-challenge-value", result.code_challenge
    assert_equal "S256", result.code_challenge_method
  end
end
