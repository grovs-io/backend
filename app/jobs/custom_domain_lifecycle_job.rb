# Enterprise hostnames never expire. Teardown suspends the row (non-resolvable) before the
# CF delete; only confirmed CF deletion hard-deletes the row.
class CustomDomainLifecycleJob
  include Sidekiq::Job
  include SingleFlightJob
  sidekiq_options queue: :maintenance, retry: 3

  GRACE = 7.days
  MAX_ROWS_PER_RUN = 50
  RUN_BUDGET_SECONDS = 90
  LOCK_TTL_SECONDS = 900

  # Separate bounds so mid-teardown suspended rows can't be starved by a glut of active ones.
  SUSPENDED_SHARE = MAX_ROWS_PER_RUN / 2
  ACTIVE_SHARE    = MAX_ROWS_PER_RUN - SUSPENDED_SHARE

  def perform
    return unless Grovs.custom_domains_enabled?

    single_flight!(key: "custom_domain_lifecycle", ttl: LOCK_TTL_SECONDS.seconds) do |deadline|
      @deadline = deadline

      suspended = CustomHostname.where(status: "suspended")
                                .order(:updated_at)
                                .limit(SUSPENDED_SHARE)
                                .to_a
      saas_active = CustomHostname.where(source: CustomHostname::SOURCE_SAAS,
                                         status: %w[pending active])
                                  .order(:updated_at)
                                  .limit(ACTIVE_SHARE)
                                  .to_a

      candidates = suspended + saas_active
      @entitled_instance_ids = entitled_instance_ids_for(candidates)

      candidates.each do |ch|
        break if budget_exhausted?
        ch.with_lock do
          if ch.status == "suspended"
            finalize_teardown(ch)
          elsif ch.saas?
            process_active(ch)
          end
        end
      rescue StandardError => e
        Rails.logger.error("[CustomDomainLifecycleJob] hostname=#{ch&.id}: #{e.class} #{e.message}")
      end
    end
  end

  def budget_exhausted?
    return false unless @deadline
    Time.current >= @deadline - (LOCK_TTL_SECONDS - RUN_BUDGET_SECONDS)
  end

  def entitled_instance_ids_for(candidates)
    instance_ids = candidates.map { |ch| ch.project&.instance_id }.compact.uniq
    return Set.new if instance_ids.empty?

    stripe_ids = StripeSubscription.where(instance_id: instance_ids, active: true)
                                   .pluck(:instance_id)
    enterprise_ids = EnterpriseSubscription.where(instance_id: instance_ids, active: true)
                                           .pluck(:instance_id)
    Set.new(stripe_ids + enterprise_ids)
  end

  private

  def entitled?(custom_hostname)
    instance_id = custom_hostname.project&.instance_id
    return @entitled_instance_ids.include?(instance_id) if @entitled_instance_ids
    custom_hostname.project.instance.custom_domains_entitled?
  end

  def process_active(custom_hostname)
    if entitled?(custom_hostname)
      custom_hostname.update!(grace_until: nil) if custom_hostname.grace_until.present?
    elsif custom_hostname.grace_until.nil?
      custom_hostname.update!(grace_until: GRACE.from_now)
    elsif custom_hostname.grace_until.past?
      begin_teardown(custom_hostname)
    end
  end

  def begin_teardown(custom_hostname)
    domain = custom_hostname.domain
    domain.update!(active_custom_host: nil) if domain.active_custom_host == custom_hostname.hostname
    custom_hostname.update!(status: "suspended", grace_until: nil)
    finalize_teardown(custom_hostname)
  end

  def finalize_teardown(custom_hostname)
    return unless CloudflareCustomHostnameService.delete(cf_id: custom_hostname.cf_custom_hostname_id)

    target = Audit.target_for(custom_hostname).merge("hostname" => custom_hostname.hostname, "purpose" => custom_hostname.purpose)
    instance_id = custom_hostname.project.instance_id
    ActiveRecord::Base.transaction do
      custom_hostname.destroy!
      Audit.record(instance_id: instance_id, action: "custom_domain.torn_down",
                        actor: AuditActor.system(self.class.name), target: target)
    end
  end
end
