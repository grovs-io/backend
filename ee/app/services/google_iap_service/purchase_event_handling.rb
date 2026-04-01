module GoogleIapService::PurchaseEventHandling
  extend ActiveSupport::Concern

  private

  # Centralized event gateway — all Google purchase event creation flows through here.
  # Mirrors Apple's handle_subscription_event_type with the same 3-step dedup pattern:
  #   1. Find existing unvalidated mobile SDK event → validate it
  #   2. Check if webhook-validated event already exists → short-circuit
  #   3. Create new event
  def handle_google_purchase_event(event_type:, project:, **attrs)
    transaction_id = attrs[:transaction_id]
    original_transaction_id = attrs[:original_transaction_id] || transaction_id
    attrs[:original_transaction_id] = original_transaction_id

    # Step 1: Find existing mobile SDK event that needs webhook validation
    mobile_event = find_existing_google_mobile_event(event_type, transaction_id, original_transaction_id, project)
    if mobile_event
      @logger.info "Validated existing mobile event: #{event_type} for transaction: #{transaction_id}"
      return @event_creator.validate_existing(mobile_event, store_source: Grovs::Webhooks::GOOGLE, **attrs)
    end

    # Step 2: Check if webhook-validated event already exists — short-circuit on duplicate RTDN
    webhook_event = PurchaseEvent.find_by(
      event_type: event_type,
      transaction_id: transaction_id,
      project_id: project.id,
      webhook_validated: true
    )

    # Fallback to original_transaction_id only when it matches transaction_id.
    # For bundles, transaction_id is "token:product_id" while original_transaction_id
    # is the shared purchase_token — matching by it would hit unrelated bundle items.
    if !webhook_event && transaction_id.present? && transaction_id == original_transaction_id
      webhook_event = PurchaseEvent.find_by(
        event_type: event_type,
        original_transaction_id: original_transaction_id,
        project_id: project.id,
        webhook_validated: true
      )
    end

    if webhook_event
      @logger.info "Webhook event already exists: #{event_type} for transaction: #{transaction_id}"
      return webhook_event
    end

    # Step 3: Create new event with attribution
    @event_creator.create_new(event_type: event_type, project: project, store_source: Grovs::Webhooks::GOOGLE, **attrs)
  end

  # Find existing mobile SDK event that needs webhook validation.
  # Mirrors Apple's find_existing_mobile_event.
  def find_existing_google_mobile_event(event_type, transaction_id, original_transaction_id, project)
    event = PurchaseEvent.find_by(
      event_type: event_type,
      transaction_id: transaction_id,
      project_id: project.id,
      webhook_validated: false
    )
    return event if event

    # Fallback to original_transaction_id for initial purchases only.
    # For Google subscriptions, original_transaction_id is shared across renewals —
    # matching by it on a renewal would overwrite the initial purchase event.
    return nil unless transaction_id.present? && transaction_id == original_transaction_id

    PurchaseEvent.find_by(
      event_type: event_type,
      original_transaction_id: original_transaction_id,
      project_id: project.id,
      webhook_validated: false
    )
  end

  # Extract quantity from a v2 ProductLineItem.
  # Quantity lives on product_offer_details, not the line item directly.
  def extract_v2_line_item_quantity(item)
    if item.respond_to?(:product_offer_details) && item.product_offer_details.respond_to?(:quantity)
      qty = item.product_offer_details.quantity
      qty.present? && qty.to_i > 0 ? qty.to_i : 1
    else
      1
    end
  end

  # Shared timestamp extraction for Google productsv2 API responses.
  # ProductPurchaseV2 uses purchase_completion_time (ISO 8601 string), not millis.
  def extract_v2_purchase_time(obj)
    if obj.respond_to?(:purchase_completion_time) && obj.purchase_completion_time
      Time.parse(obj.purchase_completion_time)
    elsif obj.respond_to?(:purchase_time_millis) && obj.purchase_time_millis
      IapUtils.parse_ms_timestamp(obj.purchase_time_millis)
    else
      Time.current
    end
  rescue ArgumentError
    Time.current
  end
end
