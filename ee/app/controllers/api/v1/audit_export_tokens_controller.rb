class Api::V1::AuditExportTokensController < Api::V1::ProjectsBaseController
  include DashboardAuthorization
  before_action :doorkeeper_authorize!
  before_action :load_admin_instance
  before_action :require_audit_log_enabled

  def index
    tokens = @instance.audit_export_tokens.active.order(created_at: :desc)
    render json: { audit_export_tokens: tokens.map { |t| serialize(t) } }, status: :ok
  end

  def create
    name = params[:name].to_s.strip
    return render(json: { error: "name is required" }, status: :unprocessable_entity) if name.blank?
    return render(json: { error: "name is too long (max 255)" }, status: :unprocessable_entity) if name.length > 255

    token = AuditExportToken.new(instance: @instance, created_by_user: current_user, name: name)
    plain = token.generate_token
    ActiveRecord::Base.transaction do
      token.save!
      audit!("audit_export_token.created", instance_id: @instance.id, target: audit_target(token),
             changes: { "after" => { "name" => name } })
    end

    render json: { audit_export_token: serialize(token), token: plain }, status: :created
  end

  def destroy
    token = @instance.audit_export_tokens.active.find_by_hashid(params[:token_id])
    return render(json: { error: "Token not found" }, status: :not_found) unless token

    ActiveRecord::Base.transaction do
      token.revoke!
      audit!("audit_export_token.revoked", instance_id: @instance.id, target: audit_target(token),
             changes: { "before" => { "name" => token.name } })
    end
    render json: { message: "Token revoked" }, status: :ok
  end

  private

  def require_audit_log_enabled
    return if @instance.audit_log_enabled?

    render json: { error: "Audit log is not enabled for this instance" }, status: :forbidden
  end

  def serialize(token)
    { id: token.hashid, name: token.name, created_at: token.created_at, last_used_at: token.last_used_at,
      created_by_email: token.created_by_user&.email }
  end
end
