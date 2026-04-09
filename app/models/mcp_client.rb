class McpClient < ApplicationRecord
  validates :client_name, presence: true
  validates :redirect_uris, presence: true
  validates :client_id, presence: true, uniqueness: true
  validate :redirect_uris_must_be_localhost_or_https

  before_validation :generate_client_id, on: :create

  # Exact string match per OAuth 2.1 (RFC 9126) — no normalization.
  def valid_redirect_uri?(uri)
    redirect_uris.include?(uri)
  end

  private

  def generate_client_id
    self.client_id ||= SecureRandom.uuid
  end

  def redirect_uris_must_be_localhost_or_https
    return if redirect_uris.blank?

    redirect_uris.each do |uri|
      parsed = URI.parse(uri)
      next if parsed.scheme == "http" && %w[localhost 127.0.0.1].include?(parsed.host)
      next if parsed.scheme == "https"

      errors.add(:redirect_uris, "must be localhost (http) or https URLs")
      break
    rescue URI::InvalidURIError
      errors.add(:redirect_uris, "contains invalid URI: #{uri}")
      break
    end
  end
end
