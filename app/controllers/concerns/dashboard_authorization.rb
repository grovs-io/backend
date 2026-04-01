module DashboardAuthorization
  extend ActiveSupport::Concern

  included do
    after_action :verify_authorized
  end

  class_methods do
    def admin_only(*actions)
      before_action only: actions do
        instance = current_instance(require_admin: true)
        return unless instance
        @_admin_authorized_instance = instance
      end
    end
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
    head :forbidden
  end
end
