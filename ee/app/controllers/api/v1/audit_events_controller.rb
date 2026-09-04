class Api::V1::AuditEventsController < Api::V1::ProjectsBaseController
  include DashboardAuthorization

  MAX_LIMIT = 1000
  DEFAULT_LIMIT = 100

  before_action :authenticate_reader!

  ORDERS = %w[asc desc].freeze

  def index
    order = params[:order].presence || "asc"
    return render(json: { error: "order must be asc or desc" }, status: :bad_request) unless ORDERS.include?(order)

    scope = AuditEvent.where(instance_id: @instance.id).order(sequence: order)
    scope = scope.where("sequence > ?", Integer(params[:after], 10)) if params[:after].present?
    scope = scope.where("sequence < ?", Integer(params[:before], 10)) if params[:before].present?
    scope = scope.where(action: params[:event_action]) if params[:event_action].present?
    scope = scope.where("actor->>'email' = ?", params[:actor_email]) if params[:actor_email].present?
    scope = scope.where("occurred_at >= ?", Time.iso8601(params[:from])) if params[:from].present?
    scope = scope.where("occurred_at <= ?", Time.iso8601(params[:to])) if params[:to].present?
    events = scope.limit(limit_param).to_a

    sequences = events.map(&:sequence)
    render json: { schema_version: AuditEvent::SCHEMA_VERSION,
                   events: AuditEventSerializer.serialize(events),
                   next_after: sequences.max, next_before: sequences.min }, status: :ok
  rescue ArgumentError, TypeError
    render json: { error: "Invalid cursor or date" }, status: :bad_request
  end

  # Not `head`: that would shadow ActionController#head, which Doorkeeper uses to render 401s.
  def latest
    last = AuditEvent.where(instance_id: @instance.id).order(:sequence).last
    render json: { schema_version: AuditEvent::SCHEMA_VERSION,
                   sequence: last&.sequence || 0, hash: last&.hash_value }, status: :ok
  end

  private

  def limit_param
    limit = params[:limit].present? ? Integer(params[:limit], 10) : DEFAULT_LIMIT
    [[limit, 1].max, MAX_LIMIT].min
  end

  # Export tokens carry the "aet_" prefix, so a Doorkeeper bearer is never mistaken for one.
  def authenticate_reader!
    raw = request.headers["Authorization"].to_s.delete_prefix("Bearer ").strip
    if raw.start_with?("aet_")
      authenticate_export_token!(raw)
    else
      doorkeeper_authorize!
      return if performed?

      @instance = current_instance(require_admin: true)
    end
    return if performed?

    render json: { error: "Audit log is not enabled for this instance" }, status: :forbidden unless @instance.audit_log_enabled?
  end

  def authenticate_export_token!(raw)
    token = AuditExportToken.find_by_plain_token(raw) # rubocop:disable Rails/DynamicFindBy
    return render(json: { error: "Invalid or revoked token" }, status: :unauthorized) unless token

    instance = Instance.find_by(id: params[:id])
    return render(json: { error: "Forbidden" }, status: :forbidden) unless instance && instance.id == token.instance_id

    token.touch_last_used!
    skip_authorization
    @instance = instance
  end
end
