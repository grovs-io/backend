class McpCleanupJob
  include Sidekiq::Job
  sidekiq_options queue: :maintenance, retry: 3

  def perform
    purge_authorization_codes
    purge_expired_tokens
    purge_unused_clients
  end

  private

  def purge_authorization_codes
    count = McpAuthorizationCode.where("expires_at < ?", Time.current).delete_all
    Rails.logger.info("McpCleanupJob: purged #{count} expired authorization codes") if count > 0
  end

  def purge_expired_tokens
    expired = McpToken
      .where("expires_at < ?", Time.current)
      .where("created_at < ?", McpToken::MCP_REFRESH_TOKEN_TTL.ago)
      .delete_all
    Rails.logger.info("McpCleanupJob: purged #{expired} expired tokens") if expired > 0

    revoked = McpToken.where.not(revoked_at: nil).where("revoked_at < ?", 7.days.ago).delete_all
    Rails.logger.info("McpCleanupJob: purged #{revoked} stale revoked tokens") if revoked > 0
  end

  def purge_unused_clients
    count = McpClient
      .where("created_at < ?", 30.days.ago)
      .where.not(client_id: McpToken.select(:client_id).where.not(client_id: nil))
      .delete_all
    Rails.logger.info("McpCleanupJob: purged #{count} unused clients") if count > 0
  end
end
