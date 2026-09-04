# The one place a manual hostname becomes active; never performs network I/O inside the lock.
class CustomHostnameActivation
  def self.apply!(custom_hostname)
    return false unless custom_hostname.manual?

    activated = false
    # A row destroyed mid-probe is frozen, and with_lock does not raise on it — update! would.
    return false if custom_hostname.destroyed? || !CustomHostname.exists?(id: custom_hostname.id)

    custom_hostname.with_lock do
      next unless custom_hostname.status == "pending"

      ActiveRecord::Base.transaction do
        custom_hostname.update!(status: "active", verification_errors: nil,
                                activated_at: custom_hostname.activated_at || Time.current,
                                last_checked_at: Time.current)
        custom_hostname.domain.update!(active_custom_host: custom_hostname.hostname) if custom_hostname.primary?
      end
      activated = true
    end

    activated
  rescue ActiveRecord::RecordNotFound
    false
  end

  # Scoped to pending so a concurrent activation is not overwritten with a stale error.
  def self.record_failure!(custom_hostname, error)
    CustomHostname.where(id: custom_hostname.id, status: "pending")
                  .update_all(verification_errors: error, last_checked_at: Time.current)
  end
end
