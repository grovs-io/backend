class ReattributePurchaseJob
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

  def perform(purchase_event_id)
    event = PurchaseEvent.includes(:device).find_by(id: purchase_event_id)
    return unless event&.device

    # Idempotency: reattribution sets visitor_id (nil after deviceless processing) — already applied.
    return if event.visitor_id.present?

    new_platform = event.device.platform_for_metrics || Grovs::Platforms::WEB
    event_date   = (event.date || event.created_at)&.to_date || Date.current
    revenue      = event.revenue_delta || 0

    # Determine what platform was used during initial processing
    old_platform = event.store_platform || 'unknown'

    visitor = event.device.visitor_for_project_id(event.project_id)
    qty = event.quantity || 1

    # One transaction: snapshot + every stat move commit together, so a mid-job
    # failure can't leave ledger and stats disagreeing, and a Sidekiq retry
    # re-applies from scratch instead of double-incrementing.
    ActiveRecord::Base.transaction do
      # Ledger snapshots follow the reattribution (the only writer besides processing).
      event.update_columns(revenue_platform: new_platform, visitor_id: visitor&.id)

      # Move project/IAP metrics only if platform actually changed
      if old_platform != new_platform
        DailyProjectMetric.increment!(event.project_id, new_platform, event_date,
          revenue: revenue, units_sold: event.buy? ? qty : 0, cancellations: event.cancellation? ? qty : 0)
        DailyProjectMetric.increment!(event.project_id, old_platform, event_date,
          revenue: -revenue, units_sold: event.buy? ? -qty : 0, cancellations: event.cancellation? ? -qty : 0)

        if event.product_id.present?
          was_first_time = InAppProductEventService.record_purchase(event, platform: new_platform, event_date: event_date)
          InAppProductEventService.upsert_stats_correction(event, platform: old_platform, event_date: event_date,
            purchase_events: event.buy? ? -qty : 0, canceled_events: event.cancellation? ? -qty : 0,
            first_time_purchases: was_first_time ? -1 : 0,
            revenue: -revenue)
        end
      end

      if revenue != 0
        # Visitor revenue: genuinely ADDED here — processing skipped it (no device).
        if visitor
          VisitorDailyStatService.increment_visitor_event(
            visitor: visitor, event_type: :revenue, platform: new_platform,
            event_date: event_date, project_id: event.project_id, value: revenue
          )
        end

        move_link_revenue(event, old_platform, new_platform, event_date, revenue)
      end

      # Always: device-dependent IAP stats (first-time detection, device_revenue)
      # Only when platform didn't change (otherwise record_purchase above already handled it)
      if old_platform == new_platform && event.product_id.present?
        InAppProductEventService.record_device_attribution(event, platform: new_platform, event_date: event_date)
      end

      SubscriptionStateService.upsert(event)
    end
  end

  private

  # Link revenue: processing ALREADY credited it (link stats don't need a device) —
  # only MOVE it when the platform changed, never re-add.
  def move_link_revenue(event, old_platform, new_platform, event_date, revenue)
    return if event.link_id.blank? || old_platform == new_platform

    LinkDailyStatService.increment_link_event(
      event_type: :revenue, project_id: event.project_id, link_id: event.link_id,
      platform: new_platform, event_date: event_date, value: revenue
    )
    LinkDailyStatService.increment_link_event(
      event_type: :revenue, project_id: event.project_id, link_id: event.link_id,
      platform: old_platform, event_date: event_date, value: -revenue
    )
  end
end
