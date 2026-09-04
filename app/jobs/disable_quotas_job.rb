class DisableQuotasJob
  include Sidekiq::Job
  sidekiq_options queue: :default, retry: 3

  def perform
    return if Grovs.self_hosted? # no quota enforcement when self-hosted

    # Enforcement first: a Stripe-side failure re-raises, and must not cost the whole cycle.
    disable_quotas()

    send_quotas_to_stripe()
  rescue StandardError => e
    Rails.logger.error "DisableQuotasJob failed: #{e.class} - #{e.message}"
    raise
  end

  def send_quotas_to_stripe
    Rails.logger.debug("Sending quotas to stripe")

    Instance.find_each(batch_size: 1000) do |instance|
      StripeService.set_usage(instance)
    rescue ProjectService::MauReadUnavailable => e
      # Skip this instance, keep the loop going: no usage pushed from a failed CH read.
      Rails.logger.error("clickhouse.mau.read_failed instance=#{instance.id} — usage not sent: #{e.message}")
    end
  end

  def save_quota!(instance)
    return instance.save! unless instance.quota_exceeded_changed?

    ActiveRecord::Base.transaction do
      instance.save!
      Audit.record(instance_id: instance.id, action: instance.quota_exceeded ? "quota.disabled" : "quota.restored",
                        actor: AuditActor.system(self.class.name), target: Audit.target_for(instance))
    end
  end

  def disable_quotas
    Rails.logger.debug("Disabling quotas for projects")
    project_helper = ProjectService.new
    
    free_pass_instance_ids = [ENV['PUBLIC_GO_PROJECT_IDENTIFIER_ID']]

    ids = ENV['FREE_PASS_PROJECT_IDS'].to_s.split(',')
    free_pass_instance_ids += ids

    instances = Instance.all.where.not(id: free_pass_instance_ids)
    instances.find_each(batch_size: 1000) do |instance|
      
      subscription = instance.subscription
      enterprise_subscription = instance.valid_enterprise_subscription

      if !subscription && !enterprise_subscription
        quantity = project_helper.current_mau(instance)
        if quantity > Grovs.free_mau_count
          instance.quota_exceeded = true
        else
          instance.quota_exceeded = false
        end

        save_quota!(instance)
      end

      if enterprise_subscription
        instance.quota_exceeded = false
        save_quota!(instance)
      end

      QuotaAlertJob.perform_async(instance.id)
    rescue ProjectService::MauReadUnavailable => e
      # Raised before any save! — quota_exceeded stays untouched; next run self-corrects.
      Rails.logger.error("clickhouse.mau.read_failed instance=#{instance.id} — quota pass skipped: #{e.message}")
    rescue StandardError => e
      Rails.logger.error("Error processing instance #{instance.id}: #{e.message}")

    end
  end
end