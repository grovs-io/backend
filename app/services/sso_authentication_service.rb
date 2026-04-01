require "base64"
require "json"

class SsoAuthenticationService
  STATE_TTL = 600 # 10 minutes

  # Returns auth URL string for the given provider.
  def self.build_auth_url(provider:)
    state = build_state(provider: provider)

    case provider
    when Grovs::SSO::MICROSOFT
      build_microsoft_auth_url(state)
    when Grovs::SSO::GOOGLE
      build_google_auth_url(state)
    else
      raise ArgumentError, "Invalid provider"
    end
  end

  # Returns User (finds or creates from OmniAuth auth hash).
  def self.find_or_create_from_auth(auth_hash:)
    name  = auth_hash.info.display_name || auth_hash.info.name
    email = auth_hash.info.email

    user = User.find_by(email: email)

    if user
      if user.provider.present? && user.provider != auth_hash.provider
        raise "This email is associated with a different login method."
      end

      user.uid = auth_hash.uid
      user.provider ||= auth_hash.provider
      user.save!
    else
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
  def self.build_state(provider:)
    payload = {
      provider: provider,
      ts: Time.now.to_i
    }
    token = Base64.urlsafe_encode64(payload.to_json)
    signature = OpenSSL::HMAC.hexdigest("SHA256", state_signing_key, token)
    "#{token}.#{signature}"
  end

  # Returns Boolean.
  def self.valid_state?(state:)
    return false if state.blank?

    token, signature = state.split(".")
    return false if token.blank? || signature.blank?

    expected = OpenSSL::HMAC.hexdigest("SHA256", state_signing_key, token)
    return false unless ActiveSupport::SecurityUtils.secure_compare(signature, expected)

    payload = JSON.parse(Base64.urlsafe_decode64(token))
    return false if (Time.now.to_i - payload["ts"].to_i) > STATE_TTL

    true
  rescue StandardError
    false
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
