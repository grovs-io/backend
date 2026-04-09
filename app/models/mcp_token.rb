class McpToken < ApplicationRecord
  include Hashid::Rails

  belongs_to :user

  validates :token_digest, presence: true, uniqueness: true
  validates :name, presence: true, length: { maximum: 255 }

  MCP_TOKEN_TTL = 1.hour
  MCP_REFRESH_TOKEN_TTL = 90.days

  scope :active, -> { where(revoked_at: nil).where("expires_at > ?", Time.current) }
  # For dashboard: shows tokens whose refresh token is still valid (90-day sliding window).
  # The access token may have expired, but the app can still refresh.
  scope :connected, -> { where(revoked_at: nil).where("created_at > ?", MCP_REFRESH_TOKEN_TTL.ago) }

  attr_reader :plain_refresh_token

  def generate_token
    plain_token = SecureRandom.hex(32)
    self.token_digest = Digest::SHA256.hexdigest(plain_token)
    self.expires_at ||= MCP_TOKEN_TTL.from_now

    plain_refresh = SecureRandom.hex(32)
    self.refresh_token_digest = Digest::SHA256.hexdigest(plain_refresh)
    @plain_refresh_token = plain_refresh

    plain_token
  end

  def self.find_by_plain_token(plain_token)
    return nil if plain_token.blank?

    digest = Digest::SHA256.hexdigest(plain_token)
    active.find_by(token_digest: digest)
  end

  def self.find_by_refresh_token(plain_refresh)
    return nil if plain_refresh.blank?

    digest = Digest::SHA256.hexdigest(plain_refresh)
    where(revoked_at: nil)
      .where("created_at > ?", MCP_REFRESH_TOKEN_TTL.ago)
      .find_by(refresh_token_digest: digest)
  end

  def revoke!
    update!(revoked_at: Time.current)
  end

  def touch_last_used!
    update_column(:last_used_at, Time.current)
  end
end
