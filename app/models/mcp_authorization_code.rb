class McpAuthorizationCode < ApplicationRecord
  belongs_to :user

  validates :code, presence: true, uniqueness: true
  validates :redirect_uri, presence: true
  validates :expires_at, presence: true
  validates :client_id, presence: true

  scope :valid, -> { where(used_at: nil).where("expires_at > ?", Time.current) }

  def self.generate_for(user:, redirect_uri:, client_id:, code_challenge: nil, code_challenge_method: nil, state: nil, scope: nil)
    create!(
      user: user,
      code: SecureRandom.hex(32),
      redirect_uri: redirect_uri,
      client_id: client_id,
      code_challenge: code_challenge,
      code_challenge_method: code_challenge_method,
      state: state,
      scope: scope,
      expires_at: 60.seconds.from_now
    )
  end

  # Returns the McpAuthorizationCode record (not just user) so caller can verify PKCE
  def self.exchange(code:, redirect_uri:, client_id:)
    record = valid.find_by(code: code, redirect_uri: redirect_uri, client_id: client_id)
    return nil unless record

    updated = valid
      .where(id: record.id)
      .update_all(used_at: Time.current)

    return nil unless updated == 1

    record.reload
    record
  end

end
