class RefreshPurchaseClickhouseRowJob
  include Sidekiq::Job
  sidekiq_options queue: :events, retry: 3

  # A processed purchase never re-enters ProcessPurchaseEventJob, so a later session_id needs re-delivery.
  def perform(purchase_event_id)
    event = PurchaseEvent.includes(:device).find_by(id: purchase_event_id)
    return unless event

    # Nudged, not restamped: created_at is also the partition key and SessionBuildJob's purchase window.
    ProcessPurchaseEventJob.dual_write_clickhouse(event, version_ts: event.created_at + 0.001.seconds)
  end
end
