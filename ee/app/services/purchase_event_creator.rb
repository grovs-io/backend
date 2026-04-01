class PurchaseEventCreator
  include PurchaseAttributionService

  def initialize
    @logger = Rails.logger
  end

  # Validate an existing SDK-submitted event with webhook data and dispatch processing.
  # Used when a mobile SDK event is confirmed by a store webhook, or when a Google
  # webhook updates an existing event.
  def validate_existing(event, store_source:, **attrs)
    old_usd = event.usd_price_cents

    update_attrs = {
      webhook_validated: true,
      store: true,
      store_source: store_source,
      identifier: attrs[:identifier],
      original_transaction_id: attrs[:original_transaction_id],
      product_id: attrs[:product_id],
      date: attrs[:date],
      expires_date: attrs[:expires_date],
      purchase_type: attrs[:purchase_type],
      order_id: attrs[:order_id]
    }

    # Only update quantity if provided and positive (don't overwrite existing with nil)
    update_attrs[:quantity] = attrs[:quantity] if attrs[:quantity].present? && attrs[:quantity] > 0

    # Subscriptions: server price is authoritative. One-time: SDK price wins.
    if attrs[:purchase_type] == Grovs::Purchases::TYPE_SUBSCRIPTION || event.price_cents.nil? || event.price_cents == 0
      update_attrs[:price_cents] = attrs[:price_cents]&.to_i
      update_attrs[:currency] = attrs[:currency]
    end

    event.update!(update_attrs)

    if event.processed? && event.usd_price_cents.to_i != old_usd.to_i
      ProcessPurchaseEventJob.perform_async(event.id, old_usd.to_i)
    elsif !event.processed?
      ProcessPurchaseEventJob.perform_async(event.id)
    end

    event
  end

  # Create a new purchase event from webhook data with attribution lookup.
  def create_new(event_type:, project:, store_source:, **attrs)
    transaction_id = attrs[:transaction_id]
    original_transaction_id = attrs[:original_transaction_id] || transaction_id

    attribution = find_attribution_from_previous_purchase(original_transaction_id, project)

    purchase_event = PurchaseEvent.create!(
      project_id: project.id,
      event_type: event_type,
      product_id: attrs[:product_id],
      identifier: attrs[:identifier],
      price_cents: attrs[:price_cents]&.to_i,
      currency: attrs[:currency],
      usd_price_cents: attrs[:usd_price_cents],
      date: attrs[:date],
      expires_date: attrs[:expires_date],
      transaction_id: transaction_id,
      original_transaction_id: original_transaction_id,
      webhook_validated: true,
      device_id: attribution[:device_id],
      link_id: attribution[:link_id],
      store: true,
      purchase_type: attrs[:purchase_type],
      store_source: store_source,
      quantity: attrs[:quantity] || 1,
      order_id: attrs[:order_id]
    )

    ProcessPurchaseEventJob.perform_async(purchase_event.id)
    @logger.info "Created new webhook purchase event: #{event_type} for transaction: #{transaction_id}"
    purchase_event
  rescue ActiveRecord::RecordNotUnique
    PurchaseEvent.find_by(
      event_type: event_type,
      transaction_id: transaction_id,
      project_id: project.id
    )
  end
end
