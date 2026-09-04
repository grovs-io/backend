class SsoConnection < ApplicationRecord
  class LastVerifiedDomain < StandardError; end
  class NotActive < StandardError; end

  PROVIDER_KEY = /\A#{Grovs::SSO::OIDC}:(\d+)\z/

  belongs_to :instance
  has_many :domains, class_name: "SsoConnectionDomain", dependent: :delete_all

  encrypts :client_secret

  validates :issuer, presence: true, format: { with: %r{\Ahttps://\S+\z}, message: "must be an https URL" }
  validates :client_id, :client_secret, presence: true

  def self.base_url = "#{ENV["SERVER_HOST_PROTOCOL"]}#{ENV["SERVER_HOST"]}"
  def self.redirect_uri = "#{base_url}/api/v1/identity/sso/auth/oidc/callback"

  def self.domain_of(email) = email.to_s.strip.downcase.split("@", 2)[1].to_s

  def self.for_domain(domain)
    conn = SsoConnectionDomain.verified.find_by(domain: domain.to_s.downcase)&.sso_connection
    conn if conn&.active?
  end

  def self.discover(email)
    conn = for_domain(domain_of(email))
    conn ? { connection_id: conn.id, enforce: conn.enforce } : { connection_id: nil }
  end

  # login_hint makes the IdP prompt for the typed account instead of reusing whichever session it has.
  def self.start_url(id, email: nil)
    conn = find_by(id: id)
    return nil unless conn&.active?

    url = "#{base_url}/api/v1/identity/sso/auth/oidc?c=#{conn.id}"
    email.present? ? "#{url}&login_hint=#{CGI.escape(email.to_s.strip.downcase)}" : url
  end

  def self.by_scim_token(plain)
    return nil if plain.blank?

    where(scim_enabled: true).find_by(scim_token_digest: Digest::SHA256.hexdigest(plain))
  end

  # A key binds only while its connection exists on another instance; social/dangling keys rebind.
  def self.rebindable?(provider_key, connection)
    id = provider_key.to_s[PROVIDER_KEY, 1]
    return true if id.nil? || id.to_i == connection.id

    !where(id: id).where.not(instance_id: connection.instance_id).exists?
  end

  def active? = enabled && instance.enterprise_sso_enabled? && domains.verified.exists?
  def enforcing? = enforce && active?
  def provider_key = "#{Grovs::SSO::OIDC}:#{id}"
  def verified_domain?(domain) = domains.verified.exists?(domain: domain.to_s.downcase)

  # Stamped at most once a minute so a provisioning cycle does not write on every request.
  def mark_scim_used!
    return if scim_last_used_at && scim_last_used_at > 1.minute.ago

    update_column(:scim_last_used_at, Time.current)
  end

  def rotate_scim_token!
    plain = "scim_#{SecureRandom.alphanumeric(48)}"
    update!(scim_token_digest: Digest::SHA256.hexdigest(plain), scim_enabled: true)
    plain
  end

  def reconcile_domains!(names)
    names = names.map { |n| n.to_s.strip.downcase }.uniq
    raise LastVerifiedDomain if enforce && !domains.verified.where(domain: names).exists?

    transaction do
      domains.where.not(domain: names).delete_all
      (names - domains.pluck(:domain)).each { |n| domains.create!(domain: n) }
    end
  end

  def enable_enforce!
    raise NotActive unless active?

    transaction do
      update!(enforce: true)
      revoke_sessions!(domains.verified.pluck(:domain))
    end
  end

  # Returns the number of users signed out.
  def revoke_sessions!(domain_names)
    patterns = domain_names.map { |d| "%@#{d}" }
    return 0 if patterns.empty?

    count = 0
    User.where(super_admin: false).where("email LIKE ANY (ARRAY[?])", patterns).find_each do |user|
      SsoConnections::SessionRevoker.revoke!(user)
      count += 1
    end
    count
  end
end
