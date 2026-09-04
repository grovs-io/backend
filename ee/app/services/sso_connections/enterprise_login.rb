module SsoConnections
  class EnterpriseLogin
    # RuntimeError so the callback shows the message; anything else becomes a generic failure.
    class Refused < RuntimeError; end

    def self.call(auth_hash:, connection:) = new(auth_hash, connection).call

    def initialize(auth_hash, connection)
      @auth = auth_hash
      @connection = connection
      @claims = (auth_hash.extra&.raw_info || {}).to_h.with_indifferent_access
    end

    def call
      raise Refused, "Single sign-on is not available for this organisation." unless @connection&.active?
      raise Refused, "The identity provider does not match this organisation." unless @claims[:iss] == @connection.issuer

      user = resolve_user(resolve_email)
      raise Refused, "Your account was deactivated by your organisation." if scim_deactivated?(user)

      admin = admin_claim?
      role = InstanceRole.create_or_find_by!(instance_id: @connection.instance_id, user_id: user.id) do |r|
        r.role = admin ? Grovs::Roles::ADMIN : Grovs::Roles::MEMBER
      end
      role.update!(role: Grovs::Roles::ADMIN) if admin && role.role != Grovs::Roles::ADMIN
      user
    rescue ActiveRecord::RecordNotUnique
      # Two first logins racing on JIT create: the loser re-runs the lookups and binds the winner's row.
      raise if @retried

      @retried = true
      retry
    end

    private

    def resolve_email
      email = @claims[:email].to_s.strip.downcase
      if email.present?
        raise Refused, "This email domain is not enabled for single sign-on." unless @connection.verified_domain?(SsoConnection.domain_of(email))

        return email
      end

      upn = @claims[:preferred_username].to_s.strip.downcase
      raise Refused, "Your identity provider did not supply an email address." if upn.empty?

      @scim_user = User.find_by(provider: @connection.provider_key, scim_user_name: upn)
      email = @scim_user ? @scim_user.email : upn
      raise Refused, "This email domain is not enabled for single sign-on." unless @connection.verified_domain?(SsoConnection.domain_of(email))

      email
    end

    def resolve_user(email)
      sub = @auth.uid.to_s
      user = User.find_by(provider: @connection.provider_key, uid: sub) || @scim_user || User.find_for_email(email)
      if user
        raise Refused, "Operator accounts cannot use enterprise single sign-on." if user.super_admin?
        raise Refused, "This email is linked to another organisation." unless SsoConnection.rebindable?(user.provider, @connection)

        # A rebind means the feed that provisioned this row is gone; its SCIM identity goes with it.
        user[:scim_user_name] = user[:scim_external_id] = nil if user.provider != @connection.provider_key
        user.provider = @connection.provider_key
        user.uid = sub
        SsoAuthenticationService.accept_pending_invitation(user)
        user.save! if user.changed?
        return user
      end
      raise Refused, "No account exists for this email. Ask an administrator to invite you." unless @connection.jit_provision

      User.create!(email: email, name: @auth.info&.name.presence || email, provider: @connection.provider_key,
                   uid: sub, otp_required_for_login: false)
    end

    # Under SCIM, membership belongs to the feed: a SCIM-managed user with no role was deactivated.
    def scim_deactivated?(user)
      @connection.scim_enabled && user.scim_user_name.present? &&
        !InstanceRole.exists?(instance_id: @connection.instance_id, user_id: user.id)
    end

    def admin_claim?
      value = @connection.admin_claim_value
      value.present? && (Array(@claims[:roles]).include?(value) || Array(@claims[:groups]).include?(value))
    end
  end
end
