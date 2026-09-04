module ScimV2
  # Scimitar controllers inherit ActionController::Base; SCIM is bearer-authenticated, not a form.
  module ControllerMixin
    extend ActiveSupport::Concern

    included do
      skip_forgery_protection
    end
  end
end
