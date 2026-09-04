module ScimV2
  class UsersController < Scimitar::ActiveRecordBackedResourcesController
    def create
      # ARBRC#create always inserts a fresh row; an existing address is bound to this connection.
      Scimitar::ResourcesController.instance_method(:create).bind_call(self) do |scim_resource|
        User.transaction do
          fresh = User.new
          fresh.from_scim!(scim_hash: scim_resource.as_json)
          fresh.email = fresh.scim_user_name if fresh.email.blank?
          user = User.find_for_email(fresh.email) || fresh
          if user != fresh
            raise conflict("User is already provisioned") if user.scim_member? && user.scim_user_name.present?
            raise operator_refusal if user.super_admin?
            raise conflict("User belongs to another organisation") unless SsoConnection.rebindable?(user.provider, connection)

            user.assign_attributes(scim_user_name: fresh.scim_user_name, scim_external_id: fresh.scim_external_id,
                                   name: fresh.name.presence || user.name)
            SsoAuthenticationService.accept_pending_invitation(user)
          end
          user.provider = connection.provider_key
          user.scim_active = fresh.scim_active_requested.nil? || fresh.scim_active_requested
          @scim_creating = true
          check_domain!(user, always: true)
          save!(user)
          audit("scim.user.created", user)
          record_to_scim(user)
        end
      end
    end

    def destroy
      super do |user|
        deactivate!(user)
        audit("scim.user.deleted", user)
      end
    end

    protected

    def storage_class = User

    def storage_scope
      scope = User.where(provider: connection.provider_key)
                  .or(User.where(id: InstanceRole.where(instance_id: connection.instance_id).select(:user_id)))
      foreign = SsoConnection.where.not(instance_id: connection.instance_id).pluck(:id).map { |i| "#{Grovs::SSO::OIDC}:#{i}" }
      foreign.empty? ? scope : scope.where("users.provider IS NULL OR users.provider NOT IN (?)", foreign)
    end

    def save!(record)
      super(record) do |user|
        check_domain!(user)
        was_new = user.new_record?
        user.save!
        transitioned = apply_active!(user)
        audit("scim.user.updated", user) unless was_new || @scim_creating || transitioned
      end
    end

    private

    def connection = Current.scim_connection

    def conflict(detail) = Scimitar::ErrorResponse.new(status: 409, scimType: "uniqueness", detail: detail)

    def operator_refusal = Scimitar::ErrorResponse.new(status: 403, detail: "Operator accounts cannot be provisioned")

    def check_domain!(user, always: false)
      return unless always || user.new_record? || user.email_changed?
      return if connection.verified_domain?(SsoConnection.domain_of(user.email))

      raise Scimitar::ErrorResponse.new(status: 400, scimType: "invalidValue", detail: "email domain is not enabled for this organisation")
    end

    # Returns true when the membership changed, so the caller does not also log a generic update.
    def apply_active!(user)
      wanted = user.scim_active_requested
      return false if wanted.nil? || wanted == user.scim_member?

      wanted ? activate!(user) : deactivate!(user)
      true
    end

    def activate!(user)
      InstanceRole.create_or_find_by!(instance_id: connection.instance_id, user_id: user.id) { |r| r.role = Grovs::Roles::MEMBER }
      audit("scim.user.reactivated", user) unless user.previously_new_record? || @scim_creating
    end

    def deactivate!(user)
      raise operator_refusal if user.super_admin?

      role = InstanceRole.find_by(instance_id: connection.instance_id, user_id: user.id)
      return unless role

      other_admins = InstanceRole.where(instance_id: connection.instance_id, role: Grovs::Roles::ADMIN).where.not(user_id: user.id)
      raise Scimitar::ErrorResponse.new(status: 409, detail: "Cannot deactivate the last admin") if role.role == Grovs::Roles::ADMIN && !other_admins.exists?

      role.destroy!
      SsoConnections::SessionRevoker.revoke!(user)
      audit("scim.user.deactivated", user)
    end

    def audit(action, user)
      Audit.record(instance_id: connection.instance_id, action: action, actor: AuditActor.scim_token(connection),
                   target: Audit.target_for(user))
    end
  end
end
