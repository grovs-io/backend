module SsoConnections
  module OmniauthSetup
    module_function

    # Never raises: OmniAuth does not rescue the setup phase, so a raise here is a 500.
    def call(env)
      request = Rack::Request.new(env)
      id = connection_id_from(request)
      connection = SsoConnection.find_by(id: id)
      unless connection&.active?
        env[Grovs::SSO::ENV_SETUP_ERROR] = id.nil? && request.params["state"].present? ? "invalid_state" : "inactive"
        return
      end

      strategy = env["omniauth.strategy"]
      strategy.options.issuer = connection.issuer
      strategy.options.client_options.identifier = connection.client_id
      strategy.options.client_options.secret = connection.client_secret
      strategy.options.client_options.redirect_uri = SsoConnection.redirect_uri
      env[Grovs::SSO::ENV_CONNECTION] = connection
    rescue StandardError => e
      Rails.logger.error("[SSO] oidc setup failed: #{e.class}")
      Rails.error.report(e, handled: true)
      env[Grovs::SSO::ENV_SETUP_ERROR] = "error"
    end

    def connection_id_from(request)
      SsoAuthenticationService.state_payload(request.params["state"])&.dig("connection_id") || request.params["c"]
    end
  end
end
