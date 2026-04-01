class DisableQuotasJob
  include Sidekiq::Job
  sidekiq_options queue: :default, retry: 3

  def perform
    Rails.logger.debug("Executing 'disable_quotas , send_quotas_to_stripe' Rake task...")
    # Load Rake tasks
    send_quotas_to_stripe()

    disable_quotas()
  rescue StandardError => e
    Rails.logger.error "Error executing 'disable_quotas' Rake task: #{e.class} - #{e.message}"
    raise
  end

  def send_quotas_to_stripe
    Rails.logger.debug("Sending quotas to stripe")

    Instance.find_each(batch_size: 1000) do |instance|
      StripeService.set_usage(instance)
    end
  end

  def disable_quotas
    Rails.logger.debug("Disabling quotas for projects")
    project_helper = ProjectService.new
    
    free_pass_instance_ids = [ENV['PUBLIC_GO_PROJECT_IDENTIFIER_ID']]

    ids = ENV['FREE_PASS_PROJECT_IDS'].split(',')
    free_pass_instance_ids += ids

    instances = Instance.all.where.not(id: free_pass_instance_ids)
    instances.find_each(batch_size: 1000) do |instance|
      
      subscription = instance.subscription
      enterprise_subscription = instance.valid_enterprise_subscription

      if !subscription && !enterprise_subscription
        quantity = project_helper.current_mau(instance)
        if quantity > ENV['FREE_MAU_COUNT'].to_i
          instance.quota_exceeded = true
        else
          instance.quota_exceeded = false
        end

        instance.save!
      end

      if enterprise_subscription
        instance.quota_exceeded = false
        instance.save!
      end

      QuotaAlertJob.perform_async(instance.id)
    rescue StandardError => e
      Rails.logger.error("Error processing instance #{instance.id}: #{e.message}")
      
    end
  end
end