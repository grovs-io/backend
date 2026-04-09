require "test_helper"

class McpCleanupJobTest < ActiveSupport::TestCase
  fixtures :users

  setup do
    @job = McpCleanupJob.new
    @user = users(:admin_user)

    McpAuthorizationCode.delete_all
    McpToken.delete_all
  end

  # --- Authorization code cleanup ---

  test "deletes expired authorization codes" do
    expired = McpAuthorizationCode.create!(
      user: @user, code: SecureRandom.hex(32),
      redirect_uri: "http://localhost:3000/callback",
      client_id: "test-client",
      expires_at: 1.hour.ago
    )

    @job.perform

    assert_not McpAuthorizationCode.exists?(expired.id)
  end

  test "preserves non-expired authorization codes" do
    valid = McpAuthorizationCode.create!(
      user: @user, code: SecureRandom.hex(32),
      redirect_uri: "http://localhost:3000/callback",
      client_id: "test-client",
      expires_at: 30.seconds.from_now
    )

    @job.perform

    assert McpAuthorizationCode.exists?(valid.id)
  end

  test "preserves used but non-expired authorization codes" do
    used = McpAuthorizationCode.create!(
      user: @user, code: SecureRandom.hex(32),
      redirect_uri: "http://localhost:3000/callback",
      client_id: "test-client",
      expires_at: 30.seconds.from_now,
      used_at: 10.seconds.ago
    )

    @job.perform

    assert McpAuthorizationCode.exists?(used.id)
  end

  # --- Token cleanup: expired ---

  test "deletes tokens whose access AND refresh have both expired" do
    expired = create_mcp_token(expires_at: 1.day.ago, created_at: 91.days.ago)

    @job.perform

    assert_not McpToken.exists?(expired.id)
  end

  test "preserves tokens with expired access but valid refresh" do
    refreshable = create_mcp_token(expires_at: 1.day.ago)

    @job.perform

    assert McpToken.exists?(refreshable.id), "token with valid refresh should be preserved"
  end

  test "preserves active tokens" do
    active = create_mcp_token(expires_at: 30.days.from_now)

    @job.perform

    assert McpToken.exists?(active.id)
  end

  # --- Token cleanup: revoked ---

  test "deletes tokens revoked more than 7 days ago" do
    old_revoked = create_mcp_token(expires_at: 60.days.from_now, revoked_at: 8.days.ago)

    @job.perform

    assert_not McpToken.exists?(old_revoked.id)
  end

  test "preserves tokens revoked less than 7 days ago" do
    recent_revoked = create_mcp_token(expires_at: 60.days.from_now, revoked_at: 3.days.ago)

    @job.perform

    assert McpToken.exists?(recent_revoked.id)
  end

  # --- Mixed scenario ---

  test "only deletes what it should in a mixed set" do
    expired_code = McpAuthorizationCode.create!(
      user: @user, code: SecureRandom.hex(32),
      redirect_uri: "http://localhost:3000/callback",
      client_id: "test-client",
      expires_at: 5.minutes.ago
    )
    valid_code = McpAuthorizationCode.create!(
      user: @user, code: SecureRandom.hex(32),
      redirect_uri: "http://localhost:3000/callback",
      client_id: "test-client",
      expires_at: 30.seconds.from_now
    )
    expired_token = create_mcp_token(expires_at: 1.day.ago, created_at: 91.days.ago)
    active_token = create_mcp_token(expires_at: 30.days.from_now)
    old_revoked_token = create_mcp_token(expires_at: 60.days.from_now, revoked_at: 10.days.ago)
    recent_revoked_token = create_mcp_token(expires_at: 60.days.from_now, revoked_at: 2.days.ago)

    @job.perform

    assert_not McpAuthorizationCode.exists?(expired_code.id)
    assert McpAuthorizationCode.exists?(valid_code.id)
    assert_not McpToken.exists?(expired_token.id)
    assert McpToken.exists?(active_token.id)
    assert_not McpToken.exists?(old_revoked_token.id)
    assert McpToken.exists?(recent_revoked_token.id)
  end

  private

  def create_mcp_token(expires_at:, revoked_at: nil, created_at: nil)
    token = McpToken.new(user: @user, name: "Test Token")
    token.generate_token
    token.expires_at = expires_at
    token.revoked_at = revoked_at
    token.save!
    token.update_column(:created_at, created_at) if created_at
    token
  end
end
