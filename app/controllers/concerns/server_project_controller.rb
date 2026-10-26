# Turns a dashboard project controller subclass into a server API one: instance API key auth, no user.
module ServerProjectController
  extend ActiveSupport::Concern
  include ServerKeyAuthentication

  included do
    skip_before_action :doorkeeper_authorize!
    skip_before_action :authorize_and_load_project
    prepend_before_action :authenticate_server_project
    # Prepended last so it runs first: api_key.used/auth_failed rows need ip, user agent and request id.
    prepend_before_action :set_audit_request_context
  end

  def current_user = nil

  private

  # The key names exactly one project, so passing it is the authorization.
  def authenticate_server_project
    return unless authenticate_request

    @_authorization_performed = true
    return if @instance.push_api_enabled?

    render json: { error: "The server API needs a paid plan", error_code: "enterprise_required" }, status: :forbidden
  end
end
