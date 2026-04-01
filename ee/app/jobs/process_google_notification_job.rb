class ProcessGoogleNotificationJob
  include Sidekiq::Job
  sidekiq_options queue: :events, retry: 5

  sidekiq_retries_exhausted do |job, ex|
    project_id = IapWebhookMessage.find_by(id: job['args']&.first)&.project_id
    FailedPurchaseJob.create!(
      job_class:         job['class'],
      arguments:         job['args'],
      error_class:       ex&.class&.name || job['error_class'],
      error_message:     ex&.message || job['error_message'],
      backtrace:         (ex&.backtrace&.first(20) || []).join("\n"),
      purchase_event_id: nil,
      project_id:        project_id,
      failed_at:         Time.current
    )
    Rails.logger.error "PURCHASE DLQ: #{job['class']} permanently failed for args #{job['args']}: #{ex&.message || job['error_message']}"
  end

  def perform(iap_webhook_message_id, parsed_data, instance_id)
    instance = Instance.find_by(id: instance_id)
    return unless instance

    iap_webhook_message = IapWebhookMessage.find_by(id: iap_webhook_message_id)
    return unless iap_webhook_message

    google = GoogleIapService.new
    google.handle_notification(parsed_data, instance, iap_webhook_message)
  end
end
