module SsoConnections
  module SessionRevoker
    module_function

    def revoke!(user)
      Doorkeeper::AccessToken.where(resource_owner_id: user.id).destroy_all
      McpToken.where(user_id: user.id).delete_all
      McpAuthorizationCode.where(user_id: user.id).delete_all
    end
  end
end
