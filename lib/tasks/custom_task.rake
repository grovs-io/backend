namespace :custom_task do
  desc "Sends quotas to stripe"
  task send_quotas_to_stripe: :environment do
    stripe_helper = Helpers::StripeHelper.new

    instances = Instance.all
    instances.each do |instance|
      stripe_helper.set_usage(instance)
    end
  end

  desc "Disables quotas for projects"
  task disable_quotas: :environment do
    project_helper = Helpers::ProjectHelper.new
    
    free_pass_instance_ids = [ENV['PUBLIC_GO_PROJECT_IDENTIFIER_ID']]

    ids = ENV['FREE_PASS_PROJECT_IDS'].split(',')
    free_pass_instance_ids += ids

    instances = Instance.all.where.not(id: free_pass_instance_ids)
    instances.each do |instance|
      
      subscription = instance.subscription
      enterprise_subscription = instance.valid_enterprise_subscription

      if !subscription && !enterprise_subscription
        quantity = project_helper.current_mau(instance)
        if quantity > Grovs.free_mau_count
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
      puts "Error processing instance #{instance.id}: #{e.message}"
      
    end
  end
end
