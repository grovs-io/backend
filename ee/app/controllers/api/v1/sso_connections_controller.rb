class Api::V1::SsoConnectionsController < Api::V1::ProjectsBaseController
  include DashboardAuthorization
  before_action :doorkeeper_authorize!
  before_action :load_admin_instance
  before_action :require_entitlement
  before_action :load_connection, only: %i[destroy verify_domains create_scim_token destroy_scim_token]

  def show
    conn = @instance.sso_connection
    render json: { sso_connection: conn && serialized(conn) }, status: :ok
  end

  def upsert
    conn = @instance.sso_connection || @instance.build_sso_connection
    attrs = params.permit(:issuer, :client_id, :client_secret, :client_secret_expires_at, :jit_provision,
                          :admin_claim_value, :enabled).to_h
    attrs.delete("client_secret") if attrs["client_secret"].blank?
    conn.assign_attributes(attrs)
    if conn.new_record? || conn.issuer_changed?
      reason = SsoConnections::IssuerValidator.error_for(conn.issuer)
      return render(json: { error: reason }, status: :unprocessable_entity) if reason
    end

    revoked = nil
    ActiveRecord::Base.transaction do
      was_new = conn.new_record?
      conn.save!
      changes = Audit.diff(conn)
      conn.reconcile_domains!(params[:domains]) if params[:domains].is_a?(Array)
      revoked = apply_enforce!(conn) if params.key?(:enforce)
      audit!(was_new ? "sso_connection.created" : "sso_connection.updated", instance_id: @instance.id,
             target: Audit.target_for(conn), changes: changes)
    end
    body = { sso_connection: serialized(conn.reload) }
    body[:sessions_revoked] = revoked if revoked
    render json: body, status: :ok
  rescue ActiveRecord::RecordInvalid => e
    render json: { error: e.message }, status: :unprocessable_entity
  rescue SsoConnection::NotActive
    render json: { error: "Verify at least one domain before enforcing SSO" }, status: :unprocessable_entity
  rescue SsoConnection::LastVerifiedDomain
    render json: { error: "Turn enforcement off before removing the last verified domain" }, status: :conflict
  end

  def destroy
    conn = @connection
    return render(json: { error: "Turn enforcement off before deleting the connection" }, status: :conflict) if conn.enforce

    conn.destroy!
    audit!("sso_connection.deleted", instance_id: @instance.id, target: Audit.target_for(conn))
    render json: { message: "SSO connection removed" }, status: :ok
  end

  def verify_domains
    conn = @connection

    conn.domains.where(verified_at: nil).find_each do |d|
      next unless SsoConnections::DomainVerifier.verify!(d)

      revoked = conn.enforce ? conn.revoke_sessions!([d.domain]) : 0
      audit!("sso_connection.domain_verified", instance_id: @instance.id, target: Audit.target_for(conn),
             changes: { "domain" => d.domain, "sessions_revoked" => revoked })
    end
    render json: { sso_connection: serialized(conn.reload) }, status: :ok
  rescue SsoConnections::DomainVerifier::AlreadyClaimed
    render json: { error: "That domain is already verified by another organisation" }, status: :conflict
  end

  def create_scim_token
    conn = @connection

    plain = conn.rotate_scim_token!
    audit!("sso_connection.scim_token_rotated", instance_id: @instance.id, target: Audit.target_for(conn))
    render json: { token: plain }, status: :created
  end

  def destroy_scim_token
    conn = @connection

    conn.update!(scim_enabled: false, scim_token_digest: nil)
    audit!("sso_connection.scim_disabled", instance_id: @instance.id, target: Audit.target_for(conn))
    render json: { message: "SCIM disabled" }, status: :ok
  end

  private

  def serialized(conn) = SsoConnectionSerializer.serialize(conn, scim_base_url: "#{request.base_url}/scim/v2")

  def load_connection
    @connection = @instance.sso_connection
    render json: { error: "Not found" }, status: :not_found unless @connection
  end

  def require_entitlement
    return if @instance.enterprise_sso_enabled?

    render json: { error: "Enterprise SSO is not enabled for this instance" }, status: :forbidden
  end

  # Returns the number of users signed out, or nil when enforce did not turn on.
  def apply_enforce!(conn)
    wanted = ActiveModel::Type::Boolean.new.cast(params[:enforce])
    return nil if wanted == conn.enforce

    if wanted
      count = conn.enable_enforce!
      audit!("sso_connection.enforce_enabled", instance_id: @instance.id, target: Audit.target_for(conn), changes: { "sessions_revoked" => count })
      count
    else
      conn.update!(enforce: false)
      audit!("sso_connection.enforce_disabled", instance_id: @instance.id, target: Audit.target_for(conn))
      nil
    end
  end
end
