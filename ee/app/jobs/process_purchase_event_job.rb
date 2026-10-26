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

  # A non-nil old_usd_price_cents selects the correction path (baseline only for pre-column rows).
  def perform(purchase_event_id, old_usd_price_cents = nil)
    event = PurchaseEvent.includes(:device).find_by(id: purchase_event_id)
    return unless event

    if old_usd_price_cents
      apply_correction(event, old_usd_price_cents)
      return
    end

    # Before the transaction: no DB locks held during the exchange-rate HTTP call.
    retry_currency_conversion!(event) unless event.processed?

    claimed = ActiveRecord::Base.transaction do
      # Accounted price comes from the row the claim locks, never from the cached object.
      rows = PurchaseEvent.where(id: event.id, processed: false)
                          .update_all("processed = TRUE, accounted_usd_price_cents = COALESCE(usd_price_cents, 0)")
      if rows == 1
        event.reload # same lock: aggregates are computed from the state the claim protects
        process_event(event)
      end
      rows == 1
    end
    if claimed
      Journeys.purchased(event)
      return self.class.dual_write_clickhouse(event)
    end

    # Already processed: re-emit; non-null price drift corrects first (null baseline is not drift).
    event = PurchaseEvent.includes(:device).find_by(id: event.id)
    return if event.nil?

    accounted = event.accounted_usd_price_cents
    if accounted.present? && accounted != event.usd_price_cents.to_i
      apply_correction(event, accounted)
    else
      self.class.dual_write_clickhouse(event)
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
    visitor    = event.device&.visitor_for_project_id(event.project_id)

    persist_ledger_snapshots(event, platform, visitor)

    if event.usd_price_cents.nil? && event.buy? && (event.price_cents.blank? || event.currency.blank?)
      Rails.logger.warn "ProcessPurchaseEventJob: event #{event.id} (#{event.event_type}) has no price data, revenue will be 0"
    end

    if revenue != 0
      update_visitor_stats(event, platform, event_date, revenue, visitor: visitor)
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

  # Authoritative price arrived after processing: apply the difference as a correction.
  def apply_correction(event, old_cents)
    ActiveRecord::Base.transaction do
      # Row lock; delta from the persisted accounted price (NULL predates the column: trust arg).
      event.lock!
      accounted  = event.accounted_usd_price_cents || old_cents.to_i
      correction = (event.revenue_delta || 0) - (event.revenue_delta(accounted) || 0)
      event.update_columns(accounted_usd_price_cents: event.usd_price_cents.to_i)
      if correction != 0
        # Snapshot platform and visitor: one purchase's money must never split across two of either.
        platform   = event.revenue_platform || determine_platform(event)
        event_date = event_date_for(event)
        # Visitor credit waits for reattribution; device credit follows device_id.
        update_visitor_stats(event, platform, event_date, correction, visitor: event.visitor) if event.visitor_id.present?
        update_link_stats(event, platform, event_date, correction)
        InAppProductEventService.apply_revenue_correction(event, platform: platform, event_date: event_date, correction: correction)
        DailyProjectMetric.increment!(event.project_id, platform, event_date, revenue: correction)
      end
    end

    # Re-emit even at zero delta: cancels and zero-cent rows change fields the ledger ignores.
    self.class.dual_write_clickhouse(event)
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

  # Ledger snapshots (platform/visitor as counted): written here and by ReattributePurchaseJob only.
  def persist_ledger_snapshots(event, platform, visitor)
    event.update_columns(revenue_platform: platform, visitor_id: visitor&.id)
  end

  def update_visitor_stats(event, platform, event_date, value, visitor: nil)
    return unless event.device

    visitor ||= event.device.visitor_for_project_id(event.project_id)
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

  # Stamp after the caller's commit, then reload; never call this inside a transaction.
  def self.dual_write_clickhouse(event)
    return unless Clickhouse.enabled?

    version = Time.current
    event = PurchaseEvent.includes(:device).find_by(id: event.id) # outside the rescue: a PG error must retry
    return if event.nil? # deleted meanwhile (DeleteInstanceJob): nothing to emit, nothing to retry

    begin
      # Durable delivery (bounded retry -> DLQ): revenue must not silently drop on a CH hiccup.
      ClickhouseWriteService.deliver_purchase_events([build_clickhouse_purchase_row(event, version_ts: version)])
    rescue StandardError => e
      Rails.logger.error("ProcessPurchaseEventJob: CH dual-write failed for event #{event.id}: #{e.class} - #{e.message}")
    end
  end

  def self.build_clickhouse_purchase_row(event, version_ts:)
    # Snapshot when present; live resolve only for pre-backfill rows hit by a correction.
    visitor_id = event.visitor_id || event.device&.visitor_for_project_id(event.project_id)&.id

    {
      project_id:              event.project_id,
      event_type:              event.event_type.to_s,
      purchase_type:           event.purchase_type.to_s,
      product_id:              event.product_id.to_s,
      # Ledger's figure: a refresh during an un-accounted price rewrite must not move CH revenue.
      usd_price_cents:         (event.accounted_usd_price_cents || event.usd_price_cents).to_i,
      currency:                event.currency.to_s,
      quantity:                event.quantity || 1,
      transaction_id:          event.transaction_id.to_s,
      original_transaction_id: event.original_transaction_id.to_s,
      store_source:            event.store_source.to_s,
      device_id:               event.device_id.to_i,
      link_id:                 event.link_id.to_i,
      visitor_id:              visitor_id.to_i,
      session_id:              event.session_id.to_s,
      purchase_date:           event.date || event.created_at,
      recorded_at:             event.created_at,
      platform:                (event.revenue_platform.presence || event.store_platform).to_s,
      created_at:              version_ts
    }
  end

  def determine_platform(event)
    # Store webhooks (Apple/Google) authoritatively know the platform —
    # prefer store_platform over device.platform which may be "web" if
    # the device was first seen via a browser link click.
    if event.store_platform
      event.store_platform
    elsif event.device
      event.device.platform_for_metrics || Grovs::Platforms::WEB
    else
      Grovs::Platforms::WEB
    end
  end

  def event_date_for(event)
    (event.date || event.created_at)&.to_date || Date.current
  end
end
