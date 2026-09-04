class Current < ActiveSupport::CurrentAttributes
  attribute :actor, :ip, :user_agent, :request_id, :scim_connection
end
