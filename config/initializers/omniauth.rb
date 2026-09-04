# devise/omniauth assigns its own on_failure when loaded; requiring it first lets ours win below.
require "devise/omniauth"
OmniAuth.config.allowed_request_methods = [:get]  # Ensure this is set before middleware
OmniAuth.config.full_host = "#{ENV["SERVER_HOST_PROTOCOL"]}#{ENV["SERVER_HOST"]}"

Rails.application.config.middleware.use OmniAuth::Builder do
  OmniAuth.config.on_failure = proc do |env|
    Rails.logger.error "OmniAuth Authentication Failure: #{env['omniauth.error']}"
    Rails.logger.error "Received Redirect URI: #{env['omniauth.origin']}"
    Api::V1::Identity::Sso::SessionsController.action(:omniauth_failure).call(env)
  end

  # An unconfigured provider must not expose a callback route with nil client ids.
  if Grovs::SSO.provider_configured?(Grovs::SSO::MICROSOFT)
    provider :microsoft_graph, ENV['MICROSOFT_CLIENT_ID'], ENV['MICROSOFT_CLIENT_SECRET'],
        scope: "openid profile email offline_access User.Read Contacts.Read Directory.Read.All",
        provider_ignores_state: true, callback_path: "/api/v1/identity/sso/auth/microsoft_graph/callback"
  end

  if Grovs::SSO.provider_configured?(Grovs::SSO::GOOGLE)
    provider :google_oauth2,
            ENV["GOOGLE_CLIENT_ID"],
            ENV["GOOGLE_CLIENT_SECRET"],
            scope: 'https://www.googleapis.com/auth/userinfo.profile https://www.googleapis.com/auth/userinfo.email',
            prompt: 'select_account',
            callback_path: "/api/v1/identity/sso/auth/google_oauth2/callback",
            provider_ignores_state: true,
            access_type: 'offline'
  end

  if Grovs.ee?
    require Rails.root.join("ee/lib/grovs/oidc_strategy")
    require Rails.root.join("ee/lib/grovs/expiring_cache")
    SWD.cache = Grovs::ExpiringCache.new(expires_in: 1.hour)
    # Propagates to SWD and Rack::OAuth2; a slow issuer must not hold a Puma thread for 60s.
    OpenIDConnect.http_config do |faraday|
      faraday.options.open_timeout = 3
      faraday.options.timeout = 5
    end

    provider Grovs::OidcStrategy,
             name: Grovs::SSO::OIDC,
             request_path: "/api/v1/identity/sso/auth/oidc",
             callback_path: "/api/v1/identity/sso/auth/oidc/callback",
             discovery: true, pkce: true, response_type: :code, response_mode: :query,
             client_signing_alg: :RS256,
             scope: %i[openid email profile],
             state: ->(env) { SsoAuthenticationService.build_state(provider: Grovs::SSO::OIDC, connection_id: env[Grovs::SSO::ENV_CONNECTION].id) },
             setup: ->(env) { SsoConnections::OmniauthSetup.call(env) }
  end
end