# Explicit allowlist — `credentials` is NEVER emitted (security-critical, tests assert it).
class MigrationSourceSerializer < BaseSerializer
  attributes :id, :provider, :old_host, :provider_hosted, :extra_hosts, :enabled,
             :consecutive_failures, :first_failure_at, :last_error_status,
             :created_at, :updated_at

  def build(**)
    h = super()
    h["health"] = record.health.to_s
    h
  end
end
