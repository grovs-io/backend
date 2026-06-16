# Explicit attribute allowlist for MigrationSource. The `credentials` attribute is NEVER
# emitted — that's the security-critical guarantee. Tests assert this directly.
class MigrationSourceSerializer < BaseSerializer
  attributes :id, :provider, :old_host, :enabled,
             :consecutive_failures, :first_failure_at, :last_error_status,
             :created_at, :updated_at

  def build(**)
    h = super()
    h["health"] = record.health.to_s
    h
  end
end
