class ProcessPurchaseEventJob
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

  # @param purchase_event_id [Integer]
  # @param old_usd_price_cents [Integer, nil] when non-nil this is a price-correction
  #   run: only the revenue delta (new - old) is applied to stats.
  def perform(purchase_event_id, old_usd_price_cents = nil)
    event = PurchaseEvent.includes(:device).find_by(id: purchase_event_id)
    return unless event

    if old_usd_price_cents
      apply_correction(event, old_usd_price_cents)
      return
    end

    # Retry currency conversion BEFORE the transaction to avoid holding
    # DB locks during external HTTP calls to exchange-rate APIs.
    retry_currency_conversion!(event)

    # Single transaction: atomic claim + all stats writes.
    # If any write fails the whole thing rolls back (including processed flag)
    # so Sidekiq retry can re-claim the event.  Prevents both double-counting
    # and data loss from partial failures.
    ActiveRecord::Base.transaction do
      rows = PurchaseEvent.where(id: event.id, processed: false)
                          .update_all(processed: true)
      if rows == 0
        Rails.logger.debug { "ProcessPurchaseEventJob: event #{purchase_event_id} already processed, skipping" }
        return
      end

      process_event(event)
    end
  rescue StandardError => e
    Rails.logger.error "Failed to process purchase event #{purchase_event_id}: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
    raise
  end

  private

  def process_event(event)
    platform   = determine_platform(event)
    event_date = event_date_for(event)
    revenue    = event.revenue_delta || 0

    if event.usd_price_cents.nil? && event.buy? && (event.price_cents.blank? || event.currency.blank?)
      Rails.logger.warn "ProcessPurchaseEventJob: event #{event.id} (#{event.event_type}) has no price data, revenue will be 0"
    end

    if revenue != 0
      update_visitor_stats(event, platform, event_date, revenue)
      update_link_stats(event, platform, event_date, revenue)
    end

    update_iap_stats(event, platform, event_date)

    DailyProjectMetric.increment!(
      event.project_id, platform, event_date,
      revenue:       revenue,
      units_sold:    event.buy? ? event.quantity : 0,
      cancellations: event.cancellation? ? event.quantity : 0
    )

    SubscriptionStateService.upsert(event)
  end

  # Webhook delivered authoritative pricing after the event was already
  # processed.  Compute the difference and apply it as a correction.
  def apply_correction(event, old_cents)
    old_delta  = event.revenue_delta(old_cents.to_i)
    new_delta  = event.revenue_delta
    correction = (new_delta || 0) - (old_delta || 0)
    return if correction == 0

    platform   = determine_platform(event)
    event_date = event_date_for(event)

    ActiveRecord::Base.transaction do
      update_visitor_stats(event, platform, event_date, correction)
      update_link_stats(event, platform, event_date, correction)
      InAppProductEventService.apply_revenue_correction(event, platform: platform, event_date: event_date, correction: correction)
      DailyProjectMetric.increment!(event.project_id, platform, event_date, revenue: correction)
    end
  end

  def retry_currency_conversion!(event)
    return unless event.buy? && event.usd_price_cents.nil?

    if event.price_cents.present? && event.currency.present?
      event.convert_price_to_usd
      if event.usd_price_cents.present?
        event.save!
      else
        raise "Currency conversion failed for event #{event.id} (#{event.currency} #{event.price_cents}), retrying"
      end
    end
  end

  # --- stats writers ---------------------------------------------------

  def update_visitor_stats(event, platform, event_date, value)
    return unless event.device

    visitor = event.device.visitor_for_project_id(event.project_id)
    return unless visitor

    VisitorDailyStatService.increment_visitor_event(
      visitor:    visitor,
      event_type: :revenue,
      platform:   platform,
      event_date: event_date,
      project_id: event.project_id,
      value:      value
    )
  end

  def update_link_stats(event, platform, event_date, value)
    return unless event.link_id.present?

    LinkDailyStatService.increment_link_event(
      event_type: :revenue,
      project_id: event.project_id,
      link_id:    event.link_id,
      platform:   platform,
      event_date: event_date,
      value:      value
    )
  end

  def update_iap_stats(event, platform, event_date)
    if event.product_id.blank?
      Rails.logger.warn "ProcessPurchaseEventJob: event #{event.id} has no product_id, skipping IAP stats"
      return
    end

    InAppProductEventService.record_purchase(event, platform: platform, event_date: event_date)
  end

  # --- helpers ----------------------------------------------------------

  def determine_platform(event)
    # Store webhooks (Apple/Google) authoritatively know the platform —
    # prefer store_platform over device.platform which may be "web" if
    # the device was first seen via a browser link click.
    if event.store_platform
      event.store_platform
    elsif event.device
      event.device.platform_for_metrics || Grovs::Platforms::WEB
    elsif event.store?
      Grovs::Platforms::WEB
    else
      Grovs::Platforms::WEB
    end
  end

  def event_date_for(event)
    (event.date || event.created_at)&.to_date || Date.current
  end
end
