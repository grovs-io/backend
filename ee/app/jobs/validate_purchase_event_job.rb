class ValidatePurchaseEventJob
  include Sidekiq::Job
  sidekiq_options queue: :events, retry: 5

  sidekiq_retries_exhausted do |job, ex|
    FailedPurchaseJob.create!(
      job_class:         job['class'],
      arguments:         job['args'],
      error_class:       ex&.class&.name || job['error_class'],
      error_message:     ex&.message || job['error_message'],
      backtrace:         (ex&.backtrace&.first(20) || []).join("\n"),
      purchase_event_id: job['args']&.first,
      project_id:        PurchaseEvent.find_by(id: job['args']&.first)&.project_id,
      failed_at:         Time.current
    )
    Rails.logger.error "PURCHASE DLQ: #{job['class']} permanently failed for args #{job['args']}: #{ex&.message || job['error_message']}"
  end

  def perform(purchase_event_id, platform)
    purchase_event = PurchaseEvent.find_by(id: purchase_event_id)
    return unless purchase_event

    validated = PurchaseValidationService.validate(purchase_event, platform)
    ProcessPurchaseEventJob.perform_async(purchase_event.id) if validated
  end
end
