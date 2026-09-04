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

    # Fire-and-forget CH dual-write — after PG transaction succeeds.
    # CH failures are logged but don't affect the PG pipeline.
    self.class.dual_write_clickhouse(event)
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

  # Webhook delivered authoritative pricing after the event was already
  # processed.  Compute the difference and apply it as a correction.
  def apply_correction(event, old_cents)
    old_delta  = event.revenue_delta(old_cents.to_i)
    new_delta  = event.revenue_delta
    correction = (new_delta || 0) - (old_delta || 0)
    return if correction == 0

    # Snapshot platform, not a recompute — a device whose platform changed since
    # processing must not split one purchase's money across two platforms.
    platform   = event.revenue_platform || determine_platform(event)
    event_date = event_date_for(event)

    ActiveRecord::Base.transaction do
      # Snapshot visitor too — a device re-pointed to a different visitor since
      # processing must not split one purchase's money across two visitors.
      update_visitor_stats(event, platform, event_date, correction, visitor: event.visitor)
      update_link_stats(event, platform, event_date, correction)
      InAppProductEventService.apply_revenue_correction(event, platform: platform, event_date: event_date, correction: correction)
      DailyProjectMetric.increment!(event.project_id, platform, event_date, revenue: correction)
    end

    # Re-insert the corrected row so CH rollups converge — ReplacingMergeTree
    # keeps the newest version, and the MV re-signs from the new usd_price_cents.
    self.class.dual_write_clickhouse(event, version_ts: Time.current)
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

  # Ledger snapshots: platform/visitor as counted. Written only here and by
  # ReattributePurchaseJob — never recomputed at read time, never touched by corrections.
  def persist_ledger_snapshots(event, platform, visitor)
    event.update_columns(revenue_platform: platform, visitor_id: visitor&.id)
  end

  # --- stats writers ---------------------------------------------------

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

  # version_ts overrides the RMT version column (created_at) so a re-insert supersedes the original.
  def self.dual_write_clickhouse(event, version_ts: nil)
    ch_row = build_clickhouse_purchase_row(event, version_ts: version_ts)
    # Durable delivery (bounded retry -> DLQ): revenue must not silently drop on a CH hiccup.
    ClickhouseWriteService.deliver_purchase_events([ch_row])
  rescue StandardError => e
    Rails.logger.error("ProcessPurchaseEventJob: CH dual-write failed for event #{event.id}: #{e.class} - #{e.message}")
  end

  def self.build_clickhouse_purchase_row(event, version_ts: nil)
    # Snapshot when present (just persisted / backfilled); live resolve only for
    # pre-backfill rows hit by a correction.
    visitor_id = event.visitor_id || event.device&.visitor_for_project_id(event.project_id)&.id

    {
      project_id:              event.project_id,
      event_type:              event.event_type.to_s,
      purchase_type:           event.purchase_type.to_s,
      product_id:              event.product_id.to_s,
      usd_price_cents:         event.usd_price_cents.to_i,
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
      created_at:              version_ts || event.created_at
    }
  end

  # CH purchase identity is the SAME key PG enforces unique: (project_id, transaction_id,
  # event_type) — CH purchase_events ORDER BY mirrors idx_purchase_events_unique_txn. This is
  # already correct per purchase-event-type: a renewal carries a fresh transaction_id (new
  # row), a refund/cancel differs by event_type (coexists with the buy), and a restore reuses
  # the original transaction_id (PG rejects the dup; CH collapses it). PurchaseEvent guarantees
  # a non-blank transaction_id at save (assign_unique_transaction_id), so no fallback is needed
  # here — the no-provider-id case gets a unique id upstream.

  # --- helpers ----------------------------------------------------------

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
