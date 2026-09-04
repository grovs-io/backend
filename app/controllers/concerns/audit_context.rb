module AuditContext
  extend ActiveSupport::Concern

  included do
    before_action :set_audit_request_context
  end

  private

  def set_audit_request_context
    Current.ip = request.remote_ip
    # Rack headers are ASCII-8BIT; invalid UTF-8 would make JSON.generate raise in compute_hash.
    Current.user_agent = request.user_agent.to_s.dup.force_encoding(Encoding::UTF_8).scrub("?").first(512)
    Current.request_id = request.request_id
  end

  def audit!(action, instance_id:, target: {}, changes: {}, outcome: "success")
    Audit.record(instance_id: instance_id, action: action, target: target, changes: changes,
                      outcome: outcome, actor: audit_actor)
  end

  def audit_diff(record)
    Audit.diff(record)
  end

  def audit_target(record)
    Audit.target_for(record)
  end

  def audit_actor
    Current.actor ||= current_user && AuditActor.user(current_user, via: "dashboard")
  end
end
