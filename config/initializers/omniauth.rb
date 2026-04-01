OmniAuth.config.allowed_request_methods = [:get]  # Ensure this is set before middleware
OmniAuth.config.full_host = "#{ENV["SERVER_HOST_PROTOCOL"]}#{ENV["SERVER_HOST"]}"

Rails.application.config.middleware.use OmniAuth::Builder do
  OmniAuth.config.on_failure = proc do |env|
    Rails.logger.error "OmniAuth Authentication Failure: #{env['omniauth.error']}"
    Rails.logger.error "Received Redirect URI: #{env['omniauth.origin']}"
    Api::V1::Identity::Sso::SessionsController.action(:omniauth_failure).call(env)
  end

  provider :microsoft_graph, ENV['MICROSOFT_CLIENT_ID'], ENV['MICROSOFT_CLIENT_SECRET'],
      scope: "openid profile email offline_access User.Read Contacts.Read Directory.Read.All",
      provider_ignores_state: true, callback_path: "/api/v1/identity/sso/auth/microsoft_graph/callback"

  provider :google_oauth2,
          ENV["GOOGLE_CLIENT_ID"],
          ENV["GOOGLE_CLIENT_SECRET"],
          scope: 'https://www.googleapis.com/auth/userinfo.profile https://www.googleapis.com/auth/userinfo.email',
          prompt: 'select_account',
          callback_path: "/api/v1/identity/sso/auth/google_oauth2/callback",
          provider_ignores_state: true,
          access_type: 'offline'
end