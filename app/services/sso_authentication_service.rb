require "base64"
require "json"

class SsoAuthenticationService
  STATE_TTL = 600 # 10 minutes

  # Returns Boolean.
  def self.provider_configured?(provider)
    Grovs::SSO.provider_configured?(provider)
  end

  # Returns Array of provider identifiers that have credentials configured.
  def self.available_providers
    Grovs::SSO.available_providers
  end

  # Returns Boolean.
  def self.sso_enabled?
    Grovs::SSO.enabled?
  end

  # Returns auth URL string for the given provider.
  def self.build_auth_url(provider:)
    raise ArgumentError, "Invalid provider" unless Grovs::SSO::PROVIDER_ENV_KEYS.key?(provider)
    raise ArgumentError, "SSO provider '#{provider}' is not configured" unless provider_configured?(provider)

    state = build_state(provider: provider)

    case provider
    when Grovs::SSO::MICROSOFT
      build_microsoft_auth_url(state)
    when Grovs::SSO::GOOGLE
      build_google_auth_url(state)
    else
      # Adding to PROVIDER_ENV_KEYS without a branch here must fail loudly, not return nil.
      raise ArgumentError, "Invalid provider"
    end
  end

  # Returns User (finds or creates from OmniAuth auth hash).
  def self.find_or_create_from_auth(auth_hash:)
    name  = auth_hash.info.display_name || auth_hash.info.name
    # Canonicalized like Devise stores it, or a mixed-case IdP email misses the account.
    email = auth_hash.info.email.to_s.strip.downcase
    raise "Your identity provider did not supply an email address." if email.empty?
    raise SsoEnforcement::REFUSAL if SsoEnforcement.enforced_connection_id(email)

    # Match the immutable (provider, uid) before email — a forged email claim can't spoof it.
    identified = User.find_by(provider: auth_hash.provider, uid: auth_hash.uid)
    if identified
      accept_pending_invitation(identified)
      identified.save! if identified.changed?
      return identified
    end

    user = User.find_for_email(email)

    if user
      if user.provider.present? && user.provider != auth_hash.provider
        raise "This email is associated with a different login method."
      end

      # nOAuth gate: don't bind SSO to an existing account on an unverified email claim.
      unless idp_email_verified?(auth_hash)
        raise "Your identity provider could not verify this email address."
      end

      user.uid = auth_hash.uid
      user.provider ||= auth_hash.provider
      accept_pending_invitation(user)
      user.save!
    else
      # Invite-only when self-hosted; the raise is reflected into a redirect param.
      if Grovs.self_hosted?
        # Domain + digest, not the address: keeps PII out of centralized logs.
        Rails.logger.warn(
          "[SSO] rejected uninvited sign-in (domain=#{email.split('@').last} " \
          "id=#{Digest::SHA256.hexdigest(email)[0, 12]})"
        )
        raise "No account exists for this email. Ask an administrator to invite you, then sign in with SSO."
      end

      user = User.create!(
        email: email,
        name: name,
        provider: auth_hash.provider,
        uid: auth_hash.uid
      )
    end

    user
  end

  # Returns HMAC-signed state string.
  def self.build_state(provider:, connection_id: nil)
    payload = { provider: provider, ts: Time.now.to_i }
    payload[:connection_id] = connection_id if connection_id
    token = Base64.urlsafe_encode64(payload.to_json)
    signature = OpenSSL::HMAC.hexdigest("SHA256", state_signing_key, token)
    "#{token}.#{signature}"
  end

  # Returns the signed payload Hash, or nil when the signature or TTL fails.
  def self.state_payload(state)
    return nil if state.blank?

    token, signature = state.split(".")
    return nil if token.blank? || signature.blank?

    expected = OpenSSL::HMAC.hexdigest("SHA256", state_signing_key, token)
    return nil unless ActiveSupport::SecurityUtils.secure_compare(signature, expected)

    payload = JSON.parse(Base64.urlsafe_decode64(token))
    return nil if (Time.now.to_i - payload["ts"].to_i) > STATE_TTL

    payload
  rescue StandardError
    nil
  end

  # Returns Boolean.
  def self.valid_state?(state:)
    !state_payload(state).nil?
  end

  # Consume the invite, or the link stays valid and can reset this account.
  def self.accept_pending_invitation(user)
    return unless user.invitation_token.present? && user.invitation_accepted_at.nil?

    user.invitation_accepted_at = Time.current
    user.invitation_token = nil
  end

  def self.idp_email_verified?(auth_hash)
    case auth_hash.provider
    when Grovs::SSO::GOOGLE
      true
    when Grovs::SSO::MICROSOFT
      # Only xms_edov is tenant-verified; generic email claims are the nOAuth vector.
      raw = auth_hash.respond_to?(:extra) ? auth_hash.extra&.raw_info : nil
      ActiveModel::Type::Boolean.new.cast(raw && raw["xms_edov"]) || false
    else
      false
    end
  end

  private

  def self.state_signing_key
    Rails.application.secret_key_base
  end

  def self.build_microsoft_auth_url(state)
    strategy = OmniAuth::Strategies::MicrosoftGraph.new(
      nil,
      ENV["MICROSOFT_CLIENT_ID"],
      ENV["MICROSOFT_CLIENT_SECRET"]
    )

    strategy.client.auth_code.authorize_url(
      redirect_uri: "#{ENV["SERVER_HOST_PROTOCOL"]}#{ENV["SERVER_HOST"]}/api/v1/identity/sso/auth/microsoft_graph/callback",
      scope: "openid profile email offline_access user.read contacts.read Directory.Read.All",
      response_type: "code",
      state: state
    )
  end

  def self.build_google_auth_url(state)
    strategy = OmniAuth::Strategies::GoogleOauth2.new(
      nil,
      ENV["GOOGLE_CLIENT_ID"],
      ENV["GOOGLE_CLIENT_SECRET"]
    )

    strategy.client.auth_code.authorize_url(
      redirect_uri: "#{ENV["SERVER_HOST_PROTOCOL"]}#{ENV["SERVER_HOST"]}/api/v1/identity/sso/auth/#{Grovs::SSO::GOOGLE}/callback",
      scope: "https://www.googleapis.com/auth/userinfo.profile https://www.googleapis.com/auth/userinfo.email",
      prompt: "select_account",
      access_type: "offline",
      state: state
    )
  end
end
