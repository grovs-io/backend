module DashboardAuthorization
  extend ActiveSupport::Concern

  included do
    after_action :verify_authorized
  end

  private

  def skip_authorization
    @_authorization_performed = true
  end

  def verify_authorized
    return if @_authorization_performed
    return if performed? && response.status.in?([401, 403, 404])

    action = "#{self.class.name}##{action_name}"
    Rails.logger.error("[AUTH] Authorization not performed: #{action}")
    # Mutate the response directly: render/head here would raise DoubleRenderError
    # (500) when the action already rendered, and the intent is a clean 403.
    response.status = 403
    response.body = ""
  end
end
