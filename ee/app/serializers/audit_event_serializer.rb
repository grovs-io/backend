class AuditEventSerializer < BaseSerializer
  attributes :id, :sequence, :action, :outcome, :actor, :target, :ip, :user_agent, :request_id, :prev_hash

  def build(**)
    h = super()
    h["occurred_at"] = record.occurred_at.utc.iso8601(6)
    h["changes"] = record.changes_data
    h["hash"] = record.hash_value
    h
  end
end
