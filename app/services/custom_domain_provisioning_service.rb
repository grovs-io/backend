# Reserves the DB row inside a transaction BEFORE the Cloudflare call; a CF failure is
# compensated by removing the reserved row. Teardown suspends (non-resolvable) before the
# CF delete, so a failed delete never leaves the domain still serving traffic.
class CustomDomainProvisioningService
  Result   = Struct.new(:ok, :custom_hostname, :error, :status, keyword_init: true)
  Conflict = Class.new(StandardError)

  def self.create(project:, hostname:, as_enterprise: false, purpose: Grovs::Hostnames::PURPOSE_PRIMARY)
    unless Grovs::Hostnames::PURPOSES.include?(purpose)
      return Result.new(ok: false, error: "Invalid purpose", status: :unprocessable_entity)
    end

    hostname = hostname.to_s.strip.downcase.delete_suffix(".")
    instance = project.instance

    # Primary and migration share the single custom-domains entitlement.
    unless as_enterprise || instance.custom_domains_entitled?
      return Result.new(ok: false, error: "An active subscription is required", status: :payment_required)
    end
    unless hostname.ascii_only?
      return Result.new(ok: false, error: "Custom domain must use ASCII (punycode) encoding", status: :unprocessable_entity)
    end

    # Scope to this purpose so a failed primary isn't reaped during a migration provisioning.
    reap_failed(project.custom_hostnames.where(purpose: purpose))

    unless DomainConfigurationService.custom_hostname_available?(hostname)
      return Result.new(ok: false, error: "This domain is not available", status: :unprocessable_entity)
    end

    # Self-serve creates are SaaS-sourced; only admin (as_enterprise) and manual mint enterprise.
    manual = Grovs.manual_custom_domains?
    if manual && Grovs.ingress_host.blank?
      return Result.new(ok: false, status: :unprocessable_entity,
                        error: "Set SERVER_HOST or SELF_HOSTED_INGRESS_HOST before adding a domain")
    end
    source = as_enterprise || manual ? CustomHostname::SOURCE_ENTERPRISE : CustomHostname::SOURCE_SAAS

    custom_hostname = ActiveRecord::Base.transaction do
      raise Conflict if project.custom_hostnames.where(purpose: purpose).exists?

      CustomHostname.create!(
        project: project, domain: project.domain, hostname: hostname,
        status: manual ? "pending" : "provisioning", source: source, purpose: purpose
      )
    end

    return Result.new(ok: true, custom_hostname: custom_hostname) if manual

    cf = CloudflareCustomHostnameService.create(hostname: hostname, ssl_method: "txt")
    unless cf[:success] && cf[:cf_id].present?
      # A crashed earlier create may have left a CF hostname behind; re-create fails. Adopt
      # the existing CF hostname so the customer isn't permanently wedged.
      cf = CloudflareCustomHostnameService.lookup(hostname: hostname)
      unless cf[:success] && cf[:cf_id].present?
        custom_hostname.destroy!
        return Result.new(ok: false, error: "Cloudflare provisioning failed", status: :bad_gateway)
      end
    end

    # nil-safe: HTTP-01 paths and the lookup-adoption fallback leave TXT fields blank;
    # the refresh job fills them in on the next CF poll. ssl_validation_txt_records is
    # the canonical multi-record store (handles CF's multi-CA dual issuance).
    # ownership_verification_* is the second TXT (Hostname Pre-Validation), only
    # emitted on zones with pre-validation enabled.
    custom_hostname.update!(cf_custom_hostname_id: cf[:cf_id], status: "pending",
                            ssl_status: cf[:ssl_status], ssl_method: cf[:ssl_method],
                            ssl_validation_txt_records: cf[:txt_records] || [],
                            ownership_verification_txt_name: cf[:ov_txt_name],
                            ownership_verification_txt_value: cf[:ov_txt_value])
    Result.new(ok: true, custom_hostname: custom_hostname)
  rescue ActiveRecord::RecordNotUnique, Conflict
    Result.new(ok: false, error: "A custom domain already exists or is taken", status: :conflict)
  rescue ActiveRecord::RecordInvalid => e
    # A concurrent insert can fail uniqueness after our availability check. Surface as 409,
    # not 500.
    if e.record.errors.of_kind?(:hostname, :taken)
      Result.new(ok: false, error: "A custom domain already exists or is taken", status: :conflict)
    else
      Result.new(ok: false, error: e.record.errors.full_messages.to_sentence, status: :unprocessable_entity)
    end
  end

  # Returns true when the hostname was fully removed (CF + DB). A failed CF delete leaves
  # a non-resolvable "suspended" row for the lifecycle job to retry.
  def self.destroy(custom_hostname)
    domain = custom_hostname.domain
    destroyed = false

    # Three-phase: short txn → unlocked CF call → short txn. Holding the lock across the
    # 15s CF call would block the lifecycle job and pin a Puma thread.
    custom_hostname.with_lock do
      domain.update!(active_custom_host: nil) if domain.active_custom_host == custom_hostname.hostname
      custom_hostname.update!(status: "suspended") unless custom_hostname.status == "suspended"
    end

    cf_deleted = CloudflareCustomHostnameService.delete(cf_id: custom_hostname.cf_custom_hostname_id)

    if cf_deleted
      custom_hostname.with_lock do
        next unless CustomHostname.exists?(id: custom_hostname.id)
        custom_hostname.destroy!
        destroyed = true
      end
    end

    destroyed
  rescue ActiveRecord::RecordNotFound
    true
  end

  # Hard-deletes failed rows even when CF delete fails — a same-hostname retry adopts any
  # lingering CF hostname via create()'s lookup fallback.
  def self.reap_failed(scope)
    scope.where(status: "failed").find_each do |ch|
      ch.with_lock do
        next unless ch.status == "failed"

        CloudflareCustomHostnameService.delete(cf_id: ch.cf_custom_hostname_id)
        ch.destroy!
      end
    rescue ActiveRecord::RecordNotFound
      next
    end
  end
end
