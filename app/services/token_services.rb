class TokenServices
  # Generate a unique refresh token
  def self.generate_refresh_token
    loop do
      token = SecureRandom.hex(32)
      break token unless Doorkeeper::AccessToken.by_refresh_token(token)
    end
  end

  # Generates SSO access token
  def self.generate_sso_access_token(user)
    server_key_generator_app = Doorkeeper::Application.find_by(name: "React")

    Doorkeeper::AccessToken.create(
      resource_owner_id: user.id,
      application_id: server_key_generator_app.id,
      refresh_token: generate_refresh_token,
      expires_in: Doorkeeper.configuration.access_token_expires_in.to_i,
      scopes: ''
    )
  end

  def self.revoke_user_access_token(request)
    token = request.headers['Authorization']&.split(' ')&.last

    if token
      access_token = Doorkeeper::AccessToken.by_token(token)
      if access_token && !access_token.revoked?
        access_token.revoke
      end
    end
  end

  def self.refresh_user_access_token(refresh_token)
    token = Doorkeeper::AccessToken.by_refresh_token(refresh_token)
    return nil if !token || token.revoked?
    return nil if token.created_at < 7.days.ago

    user = User.find_by(id: token.resource_owner_id)
    return nil unless user

    token.revoke
    TokenServices.generate_sso_access_token(user)
  end
end