if Grovs.ee?
  Rails.application.config.to_prepare do
    Scimitar.engine_configuration = Scimitar::EngineConfiguration.new(
      application_controller_mixin: ScimV2::ControllerMixin,
      token_authenticator: proc { |token, _options|
        connection = SsoConnection.by_scim_token(token)
        Current.scim_connection = connection
        authenticated = connection.present? && connection.active?
        connection.mark_scim_used! if authenticated
        authenticated
      }
    )
  end
end
