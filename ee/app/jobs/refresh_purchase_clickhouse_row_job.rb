class RefreshPurchaseClickhouseRowJob
  include Sidekiq::Job
  sidekiq_options queue: :events, retry: 3

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

  # Compat for jobs queued before phase 2; nothing enqueues this any more. Delete next release.
  def perform(purchase_event_id)
    event = PurchaseEvent.find_by(id: purchase_event_id)
    ProcessPurchaseEventJob.new.perform(purchase_event_id) if event&.processed?
  end
end
