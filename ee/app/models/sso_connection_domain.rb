class SsoConnectionDomain < ApplicationRecord
  DOMAIN_FORMAT = /\A(?=.{1,253}\z)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}\z/

  belongs_to :sso_connection

  before_validation :normalize
  # Self-hosted operators own the box; DNS proof would only prove they can edit their own zone.
  before_create { self.verified_at ||= Time.current if Grovs.self_hosted? }

  validates :domain, presence: true, format: { with: DOMAIN_FORMAT }, uniqueness: { scope: :sso_connection_id }

  scope :verified, -> { where.not(verified_at: nil) }

  def verified? = verified_at.present?
  def record_name = "_grovs-sso.#{domain}"
  def record_value = "grovs-sso-verification=#{verification_token}"

  private

  def normalize
    self.domain = domain.to_s.strip.downcase
    self.verification_token ||= SecureRandom.hex(16)
  end
end
