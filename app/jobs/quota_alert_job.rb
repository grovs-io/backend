class QuotaAlertJob
  include Sidekiq::Job
  sidekiq_options queue: :default, retry: 1

  def perform(instance_id)
    project_helper = ProjectService.new
    instance = Instance.find_by(id: instance_id)
    return unless instance

    free_pass_instance_ids = [ENV['PUBLIC_GO_PROJECT_IDENTIFIER_ID']]
    free_pass_instance_ids += ENV['FREE_PASS_PROJECT_IDS'].to_s.split(',')

    return if free_pass_instance_ids.include?(instance.id.to_s)

    subscription = instance.subscription
    enterprise_subscription = instance.valid_enterprise_subscription

    if !subscription && !enterprise_subscription
      current_maus = project_helper.current_mau(instance)
      free_mau_count = ENV['FREE_MAU_COUNT'].to_i
      usage_percentage = (current_maus.to_f / free_mau_count * 100).round

      if current_maus > free_mau_count
        # QUOTA EXCEEDED
        unless recently_sent?(instance, :last_quota_exceeded_sent_at)
          instance.users.find_each do |user|
            QuotaMailer.quota_exceeded(user, usage_percentage, current_maus, free_mau_count, instance.id).deliver_now
          end
          instance.update!(last_quota_exceeded_sent_at: Time.current)
        end

      elsif usage_percentage >= 85
        # QUOTA PROGRESS
        unless recently_sent?(instance, :last_quota_warning_sent_at)
          instance.users.find_each do |user|
            QuotaMailer.quota_progress(user, usage_percentage, current_maus, free_mau_count, instance.id).deliver_now
          end
          instance.update!(last_quota_warning_sent_at: Time.current)
        end
      end
    end
  end

  private

  def recently_sent?(instance, field)
    timestamp = instance.send(field)
    timestamp.present? && timestamp > 3.days.ago
  end
end

