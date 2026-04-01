module GoogleIapService::RefundHandler
  extend ActiveSupport::Concern

  REFUND_TYPE_FULL = 1
  REFUND_TYPE_QUANTITY_PARTIAL = 2

  private

  def handle_voided_notification(notification, instance, iap_webhook_message, package_name)
    voided = notification["voidedPurchaseNotification"]
    purchase_token = voided["purchaseToken"]
    order_id = voided["orderId"]
    product_type = voided["productType"]
    refund_type = voided["refundType"]

    unless purchase_token && order_id
      @logger.error "Google voided purchase notification missing purchaseToken or orderId"
      return false
    end

    iap_webhook_message.update(notification_type: "VOIDED_PURCHASE")

    buy_events = find_original_buy_events(order_id, purchase_token)

    if buy_events.empty?
      @logger.warn "No BUY events found for voided purchase: order_id=#{order_id}, token=#{purchase_token}"
      return false
    end

    project = buy_events.first.project
    iap_webhook_message.update(project_id: project.id)

    already_refunded_map = prefetch_refunded_quantities(buy_events) if refund_type == REFUND_TYPE_FULL

    buy_events.each do |buy_event|
      create_refund_for_buy(buy_event, refund_type, package_name, purchase_token, already_refunded_map)
    end

    true
  end

  def find_original_buy_events(order_id, purchase_token)
    # Primary: look up by order_id (works for bundles and new events)
    events = PurchaseEvent.where(
      order_id: order_id,
      event_type: Grovs::Purchases::EVENT_BUY
    ).to_a

    return events if events.any?

    # Fallback: pre-migration events without order_id — look up by transaction_id
    events = PurchaseEvent.where(
      transaction_id: purchase_token,
      event_type: Grovs::Purchases::EVENT_BUY
    ).to_a

    return events if events.any?

    # Also try original_transaction_id (for subscription renewals where transaction_id varies)
    PurchaseEvent.where(
      original_transaction_id: purchase_token,
      event_type: Grovs::Purchases::EVENT_BUY
    ).order(created_at: :desc).limit(1).to_a
  end

  def create_refund_for_buy(buy_event, refund_type, package_name, purchase_token, already_refunded_map)
    refund_quantity = determine_refund_quantity(buy_event, refund_type, package_name, purchase_token, already_refunded_map)
    return if refund_quantity == 0

    # Idempotency: skip if REFUND already exists for this buy event
    refund_txn_id = "#{buy_event.transaction_id}_refund"
    if PurchaseEvent.exists?(
      transaction_id: refund_txn_id,
      event_type: Grovs::Purchases::EVENT_REFUND,
      project_id: buy_event.project_id
    )
      @logger.info "Refund already exists for #{buy_event.transaction_id}, skipping"
      return
    end

    attrs = {
      transaction_id: refund_txn_id,
      original_transaction_id: buy_event.original_transaction_id,
      product_id: buy_event.product_id,
      identifier: buy_event.identifier || package_name,
      price_cents: buy_event.price_cents,
      currency: buy_event.currency,
      usd_price_cents: buy_event.usd_price_cents,
      date: Time.current,
      purchase_type: buy_event.purchase_type,
      order_id: buy_event.order_id,
      quantity: refund_quantity
    }

    @event_creator.create_new(
      event_type: Grovs::Purchases::EVENT_REFUND,
      project: buy_event.project,
      store_source: Grovs::Webhooks::GOOGLE,
      **attrs
    )

    @logger.info "Created REFUND event for #{buy_event.transaction_id} (qty: #{refund_quantity})"
  rescue ActiveRecord::RecordNotUnique
    @logger.info "Refund already exists (race condition) for #{buy_event.transaction_id}"
  end

  # Prefetch already-refunded quantities for all buy events in a single query.
  # Returns a Hash keyed by [original_transaction_id, product_id] → sum(quantity).
  def prefetch_refunded_quantities(buy_events)
    pairs = buy_events.map { |e| [e.original_transaction_id, e.product_id] }.uniq
    return {} if pairs.empty?

    # Row-value IN to avoid cross-product from independent WHERE IN clauses
    conn = ActiveRecord::Base.lease_connection
    tuples = pairs.map { |oti, pid| "(#{conn.quote(oti)}, #{conn.quote(pid)})" }.join(", ")

    PurchaseEvent.where(
      event_type: Grovs::Purchases::EVENT_REFUND,
      project_id: buy_events.first.project_id
    ).where("(original_transaction_id, product_id) IN (#{tuples})")
     .group(:original_transaction_id, :product_id).sum(:quantity)
  end

  def determine_refund_quantity(buy_event, refund_type, package_name, purchase_token, already_refunded_map)
    if refund_type == REFUND_TYPE_FULL
      already_refunded = already_refunded_map[[buy_event.original_transaction_id, buy_event.product_id]] || 0
      [buy_event.quantity - already_refunded, 0].max
    else
      # Partial quantity refund: fetch voidedQuantity from API
      fetch_voided_quantity(package_name, purchase_token) || 1
    end
  end

  def fetch_voided_quantity(package_name, purchase_token)
    # Scope to last 30 days — RTDN arrives near real-time, so the voided purchase is recent.
    # Avoids fetching the entire voided purchase history for high-refund apps.
    start_time_ms = (Time.current - 30.days).to_i * 1000

    response = @service.list_purchase_voidedpurchases(
      package_name,
      type: 0,
      start_time: start_time_ms,
      include_quantity_based_partial_refund: true
    )

    return nil unless response&.voided_purchases

    voided = response.voided_purchases.find { |vp| vp.purchase_token == purchase_token }
    voided&.voided_quantity
  rescue Google::Apis::Error => e
    @logger.warn "Failed to fetch voided quantity: #{e.message}"
    nil
  end
end
