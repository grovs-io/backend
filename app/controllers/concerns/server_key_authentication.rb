# Instance API key auth for server-to-server calls: PROJECT-KEY names the instance, ENVIRONMENT its project.
module ServerKeyAuthentication
  extend ActiveSupport::Concern

  API_KEY_USED_TTL = 24.hours

  private

  def authenticate_request
    @project_key = request.headers['PROJECT-KEY'] || request.headers['project-key']
    @environment = request.headers['ENVIRONMENT'] || request.headers['environment']

    if @project_key.blank?
      render json: { error: "Missing PROJECT-KEY in headers" }, status: :bad_request
      return false
    end

    instance = Instance.find_by(api_key: @project_key)

    unless %w[production test].include?(@environment)
      audit_api_key_failure(instance)
      render json: { error: "Invalid ENVIRONMENT value. Allowed: 'production', 'test'" }, status: :bad_request
      return false
    end

    @project = instance&.public_send(@environment == "test" ? :test : :production)

    unless @project
      audit_api_key_failure(instance)
      render json: { error: "Invalid credentials" }, status: :forbidden
      return false
    end

    @instance = instance
    Current.actor = AuditActor.api_key(instance)
    audit_api_key_use(instance)
    true
  end

  def audit_api_key_failure(instance)
    return unless instance

    audit_api_key_once_per_day(instance, "audit:api_key_failed", "api_key.auth_failed", "failure")
  end

  def audit_api_key_use(instance)
    audit_api_key_once_per_day(instance, "audit:api_key_used", "api_key.used", "success")
  end

  # First sighting of (key, ip) per day (ADR 0002). SET NX claims the slot atomically; a failed write releases it.
  def audit_api_key_once_per_day(instance, prefix, action, outcome)
    return unless instance.audit_log_enabled?

    key = "#{prefix}:#{instance.id}:#{request.remote_ip}"
    claimed = begin
      REDIS.with { |c| c.set(key, "1", nx: true, ex: API_KEY_USED_TTL.to_i) }
    rescue Redis::BaseError
      true
    end
    return unless claimed

    begin
      Audit.record(instance_id: instance.id, action: action, outcome: outcome, actor: AuditActor.api_key(instance),
                        target: Audit.target_for(instance))
    rescue StandardError
      begin
        REDIS.with { |c| c.del(key) }
      rescue Redis::BaseError
        nil
      end
      raise
    end
  end
end
