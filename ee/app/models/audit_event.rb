class AuditEvent < ApplicationRecord
  SCHEMA_VERSION = 1
  OUTCOMES = %w[success failure pending].freeze
  # The catalogue. A typo in a call site fails validation instead of minting a new action name.
  ACTIONS = %w[
    user.login user.login_failed user.logout user.sso_login
    user.password_reset_requested user.password_changed user.2fa_enabled user.2fa_disabled
    user.account_deleted user.invite_accepted
    instance.member_added instance.member_removed instance.renamed instance.revenue_collection_changed
    instance.retention_changed instance.deletion_requested instance.deleted
    mcp_token.revoked audit_export_token.created audit_export_token.revoked
    api_key.used api_key.auth_failed
    ios_configuration.updated ios_configuration.removed ios_push_configuration.updated ios_api_access_key.updated
    android_configuration.updated android_configuration.removed android_push_configuration.updated android_api_access_key.updated
    desktop_configuration.updated desktop_configuration.removed web_configuration.updated web_configuration.removed
    redirect_config.updated redirect.updated domain.updated domain.google_tracking_id_updated
    custom_domain.created custom_domain.deleted custom_domain.torn_down custom_domain.verified
    migration_source.created migration_source.updated migration_source.deleted
    link.created link.updated link.deleted
    export.link_data export.usage_data links.firebase_imported
    enterprise_subscription.created enterprise_subscription.updated subscription.changed
    retention.deletion_ran quota.disabled quota.restored
    sso_connection.created sso_connection.updated sso_connection.deleted sso_connection.domain_verified
    sso_connection.enforce_enabled sso_connection.enforce_disabled sso_connection.scim_token_rotated sso_connection.scim_disabled
    scim.user.created scim.user.updated scim.user.deactivated scim.user.reactivated scim.user.deleted
  ].freeze
  VERIFY_BATCH = 1000

  validates :instance_id, :sequence, :hash_value, :occurred_at, presence: true
  validates :action, inclusion: { in: ACTIONS }
  validates :outcome, inclusion: { in: OUTCOMES }

  def readonly?
    persisted?
  end

  # entitled: lets a call site that just removed the entitlement (enterprise deactivation) still record the transition.
  def self.record(instance_id:, action:, target: {}, changes: {}, outcome: "success",
                  actor: Current.actor, occurred_at: Time.current, entitled: nil)
    if entitled.nil?
      return nil unless Instance.find_by(id: instance_id)&.audit_log_enabled?
    elsif !entitled
      return nil
    end

    transaction(requires_new: true) do
      head = AuditChainHead.advance!(instance_id)
      row = new(
        instance_id: instance_id, sequence: head.sequence, action: action,
        actor: (actor || AuditActor.system("unknown")).stringify_keys,
        target: target.deep_stringify_keys, changes_data: Audit.redact(changes.deep_stringify_keys),
        outcome: outcome, ip: Current.ip, user_agent: Current.user_agent, request_id: Current.request_id,
        occurred_at: occurred_at, prev_hash: head.head_hash, created_at: Time.current
      )
      row.hash_value = row.compute_hash
      row.save!
      head.update!(head_hash: row.hash_value)
      row
    end
  end

  # Fixed lock order across instances so two fan-outs sharing >= 2 instances cannot deadlock.
  def self.record_for_user(user:, action:, **rest)
    user.instances.order(:id).filter_map do |instance|
      next unless instance.audit_log_enabled?

      record(instance_id: instance.id, action: action, entitled: true, **rest)
    end
  end

  # Explicit sequence cursor: find_each would batch by primary key, which is only incidentally in sequence order.
  def self.verify_chain(instance_id)
    prev = nil
    expected = 1
    count = 0
    loop do
      rows = where(instance_id: instance_id).where("sequence >= ?", expected).order(:sequence).limit(VERIFY_BATCH).to_a
      break if rows.empty?

      rows.each do |row|
        return { ok: false, sequence: row.sequence, reason: "gap: expected #{expected}" } if row.sequence != expected
        return { ok: false, sequence: row.sequence, reason: "prev_hash mismatch" } if row.prev_hash != prev
        return { ok: false, sequence: row.sequence, reason: "hash mismatch" } if row.hash_value != row.compute_hash

        prev = row.hash_value
        expected += 1
        count += 1
      end
    end
    head = AuditChainHead.find_by(instance_id: instance_id)
    if head.nil?
      return { ok: false, sequence: count + 1, reason: "truncated: chain head missing" } if count.positive?
    elsif head.sequence != count || head.head_hash != prev
      return { ok: false, sequence: count + 1, reason: "truncated: head at #{head.sequence}" }
    end

    { ok: true, count: count }
  end

  def self.deep_sort(value)
    case value
    when Hash then value.keys.sort.index_with { |k| deep_sort(value[k]) }
    when Array then value.map { |v| deep_sort(v) }
    else value
    end
  end

  def compute_hash
    Digest::SHA256.hexdigest(JSON.generate(canonical_payload))
  end

  private

  # as_json first: a Time serialises differently in memory vs after a jsonb round-trip; the hash must not care.
  def canonical_payload
    [SCHEMA_VERSION, instance_id, sequence, prev_hash, occurred_at.utc.iso8601(6), action, outcome,
     self.class.deep_sort(actor.as_json), self.class.deep_sort(target.as_json), self.class.deep_sort(changes_data.as_json),
     ip, user_agent, request_id]
  end
end
