class RefreshCustomHostnameStatusJob
  include Sidekiq::Job
  include SingleFlightJob
  sidekiq_options queue: :maintenance, retry: 3

  MAX_ROWS_PER_RUN = 50
  RUN_BUDGET_SECONDS = 90
  LOCK_TTL_SECONDS = 900

  DEADLINE = 72.hours
  RECHECK_AFTER = 1.minute
  # A live provisioning call flips to "pending" within seconds; older rows are crashed creates.
  STALE_PROVISIONING_AFTER = 15.minutes
  FAILED_RETENTION = 7.days
  # Prevents racing CustomDomainProvisioningService.destroy, which legitimately leaves a row
  # suspended for the duration of its CF DELETE call.
  ORPHANED_SUSPENDED_GRACE = 5.minutes

  def perform
    return unless Grovs.custom_domains_enabled?

    single_flight!(key: "refresh_custom_hostname_status", ttl: LOCK_TTL_SECONDS.seconds) do |deadline|
      @deadline = deadline
      recover_stuck_provisioning
      reap_failed
      reap_orphaned_suspended
      refresh_pending
    end
  end

  private

  def budget_exhausted?
    return false unless @deadline
    Time.current >= @deadline - (LOCK_TTL_SECONDS - RUN_BUDGET_SECONDS)
  end

  def reap_failed
    stale = CustomHostname.where(status: "failed")
                          .where("last_checked_at IS NULL OR last_checked_at < ?", FAILED_RETENTION.ago)
    CustomDomainProvisioningService.reap_failed(stale)
  rescue StandardError => e
    Rails.logger.error("[RefreshCustomHostnameStatusJob] reap_failed: #{e.class} #{e.message}")
  end

  # Handles migration-purpose rollback orphans (suspended + no paired MigrationSource).
  # CustomDomainLifecycleJob owns the legitimately-onboarded teardowns; we skip those.
  def reap_orphaned_suspended
    cutoff = ORPHANED_SUSPENDED_GRACE.ago
    CustomHostname.where(status: "suspended")
                  .where("updated_at <= ?", cutoff)
                  .find_each do |ch|
      break if budget_exhausted?
      next if MigrationSource.exists?(project_id: ch.project_id, old_host: ch.hostname)
      CustomDomainProvisioningService.destroy(ch)
    rescue StandardError => e
      Rails.logger.warn(message: "reap_orphaned_suspended_failed",
                        custom_hostname_id: ch&.id, hostname: ch&.hostname, error: e.message)
    end
  end

  def refresh_pending
    CustomHostname.where(status: "pending")
                  .where("last_checked_at IS NULL OR last_checked_at < ?", RECHECK_AFTER.ago)
                  .order(Arel.sql("last_checked_at ASC NULLS FIRST"))
                  .limit(MAX_ROWS_PER_RUN)
                  .find_each(batch_size: MAX_ROWS_PER_RUN) do |ch|
      break if budget_exhausted?
      ch.with_lock do
        next unless ch.status == "pending"

        # Poll CF before applying the deadline so a hostname that validated at the 72h mark
        # activates instead of being force-failed.
        cf = CloudflareCustomHostnameService.status(cf_id: ch.cf_custom_hostname_id)

        if cf[:success] && cf[:status] == "active" && cf[:ssl_status] == "active"
          ActiveRecord::Base.transaction do
            # CF clears both `validation_records` and `ownership_verification` once issued.
            # ssl_validation_txt_records goes to [] so the FE's "array non-empty"
            # rendering guard collapses cleanly to "nothing to add".
            ch.update!(status: "active", ssl_status: cf[:ssl_status], verification_errors: nil,
                       ssl_method: cf[:ssl_method],
                       ssl_validation_txt_records: cf[:txt_records] || [],
                       ownership_verification_txt_name: cf[:ov_txt_name],
                       ownership_verification_txt_value: cf[:ov_txt_value],
                       activated_at: ch.activated_at || Time.current, last_checked_at: Time.current)
            # Only the primary purpose writes active_custom_host; migration rows reach "active"
            # so MigrationResolver works, but must never be rendered into short links.
            ch.domain.update!(active_custom_host: ch.hostname) if ch.primary?
          end
        elsif ch.created_at < DEADLINE.ago
          ch.update!(status: "failed", ssl_status: cf[:ssl_status], verification_errors: cf[:verification_errors],
                     ssl_method: cf[:ssl_method],
                     ssl_validation_txt_records: cf[:txt_records] || [],
                     ownership_verification_txt_name: cf[:ov_txt_name],
                     ownership_verification_txt_value: cf[:ov_txt_value],
                     last_checked_at: Time.current)
        elsif cf[:success]
          # CF can rotate the TXT challenges between retries (new value, same name) and add
          # records mid-setup (multi-CA dual issuance: initial response carried one, later
          # response carries two). The FE re-renders the full array on every poll, so
          # writing the current CF list — empty, single, multi — is always correct.
          ch.update!(ssl_status: cf[:ssl_status], verification_errors: cf[:verification_errors],
                     ssl_method: cf[:ssl_method],
                     ssl_validation_txt_records: cf[:txt_records] || [],
                     ownership_verification_txt_name: cf[:ov_txt_name],
                     ownership_verification_txt_value: cf[:ov_txt_value],
                     last_checked_at: Time.current)
        else
          ch.update!(last_checked_at: Time.current)
        end
      end
    rescue StandardError => e
      Rails.logger.error("[RefreshCustomHostnameStatusJob] hostname=#{ch&.id}: #{e.class} #{e.message}")
    end
  end

  # Handles create() crashing between CF-create and persisting cf_id. We must delete the CF
  # hostname before freeing the DB slot — otherwise traffic stays served by a hostname we
  # no longer own.
  def recover_stuck_provisioning
    CustomHostname.where(status: "provisioning")
                  .where("created_at < ?", STALE_PROVISIONING_AFTER.ago)
                  .limit(MAX_ROWS_PER_RUN)
                  .find_each(batch_size: MAX_ROWS_PER_RUN) do |ch|
      break if budget_exhausted?
      ch.with_lock do
        next unless ch.status == "provisioning" && ch.created_at < STALE_PROVISIONING_AFTER.ago

        cf = CloudflareCustomHostnameService.lookup(hostname: ch.hostname)
        if cf[:success] && cf[:cf_id].present? && !CloudflareCustomHostnameService.delete(cf_id: cf[:cf_id])
          Rails.logger.warn("[RefreshCustomHostnameStatusJob] CF orphan delete failed; " \
                            "keeping DB row for retry. hostname=#{ch.hostname} cf_id=#{cf[:cf_id]}")
          next
        end

        ch.destroy!
      end
    rescue StandardError => e
      Rails.logger.error("[RefreshCustomHostnameStatusJob] stuck provisioning hostname=#{ch&.id}: #{e.class} #{e.message}")
    end
  end
end
