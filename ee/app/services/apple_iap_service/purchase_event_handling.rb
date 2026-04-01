module AppleIapService::PurchaseEventHandling
  extend ActiveSupport::Concern

  private

  def extract_subscription_details(verified_receipt)
    signed_transaction_info = verified_receipt.dig("data", "signedTransactionInfo")
    signed_renewal_info = verified_receipt.dig("data", "signedRenewalInfo")

    unless signed_transaction_info
      @logger.error "No signedTransactionInfo found in receipt"
      return nil
    end

    begin
      transaction = AppStoreServerApi::Utils::Decoder.decode_jws!(signed_transaction_info)
      renewal_info = nil

      if signed_renewal_info
        renewal_info = AppStoreServerApi::Utils::Decoder.decode_jws!(signed_renewal_info)
      end

      unless transaction
        @logger.error "Failed to decode transaction info"
        return nil
      end

      unless transaction["transactionId"] && transaction["originalTransactionId"] && transaction["productId"]
        @logger.error "Apple transaction missing required fields: transactionId=#{transaction['transactionId']}, " \
                      "originalTransactionId=#{transaction['originalTransactionId']}, productId=#{transaction['productId']}"
        return nil
      end

      # Extract expiration date from renewal info or transaction
      expires_date = if renewal_info && renewal_info["expiresDate"]
                       Time.at(renewal_info["expiresDate"].to_i / 1000)
                     elsif transaction["expiresDate"]
                       Time.at(transaction["expiresDate"].to_i / 1000)
                     end

      {
        transaction_id: transaction["transactionId"],
        original_transaction_id: transaction["originalTransactionId"],
        environment: transaction["environment"],
        product_id: transaction["productId"],
        identifier: transaction["bundleId"],
        price: IapUtils.convert_apple_price_to_cents(transaction["price"]),
        currency: transaction["currency"],
        start_date: transaction["purchaseDate"],
        expires_date: expires_date,
        renewal_info: renewal_info,
        web_order_line_item_id: transaction["webOrderLineItemId"],
        subscription_group_identifier: transaction["subscriptionGroupIdentifier"]
      }

    rescue JWT::DecodeError, OpenSSL::OpenSSLError, JSON::ParserError => e
      @logger.error "JWT decode error for transaction: #{e.class} - #{e.message}"
      nil
    end
  end

  def handle_subscription_event_type(event_type, subscription_info, project)
    transaction_id = subscription_info[:transaction_id]
    original_transaction_id = subscription_info[:original_transaction_id]

    # Normalize Apple-specific data into common attrs
    attrs = {
      transaction_id: transaction_id,
      original_transaction_id: original_transaction_id,
      product_id: subscription_info[:product_id],
      identifier: subscription_info[:identifier],
      price_cents: subscription_info[:price],
      currency: subscription_info[:currency],
      date: IapUtils.parse_ms_timestamp(subscription_info[:start_date]),
      expires_date: subscription_info[:expires_date],
      purchase_type: subscription_info[:purchase_type]
    }

    # First, try to find an existing event from mobile SDK that needs webhook validation
    existing_event = find_existing_mobile_event(event_type, transaction_id, original_transaction_id, project)

    if existing_event
      @logger.info "Validated existing mobile event: #{event_type} for transaction: #{transaction_id}"
      return @event_creator.validate_existing(existing_event, store_source: Grovs::Webhooks::APPLE, **attrs)
    end

    # Check if we already have a webhook-validated event for this transaction
    webhook_event = PurchaseEvent.find_by(
      event_type: event_type,
      transaction_id: transaction_id,
      project_id: project.id,
      webhook_validated: true
    )

    if webhook_event
      @logger.info "Webhook event already exists: #{event_type} for transaction: #{transaction_id}"
      return webhook_event
    end

    # Cancel old product if subscription product changed within same group
    if event_type == Grovs::Purchases::EVENT_BUY && subscription_info[:purchase_type] == Grovs::Purchases::TYPE_SUBSCRIPTION
      cancel_previous_product_on_change(original_transaction_id, subscription_info[:product_id], project)
    end

    # Create new purchase event with attribution
    @event_creator.create_new(event_type: event_type, project: project, store_source: Grovs::Webhooks::APPLE, **attrs)
  end

  # Find existing mobile event that needs webhook validation
  def find_existing_mobile_event(event_type, transaction_id, original_transaction_id, project)
    # Look for exact transaction_id match first
    event = PurchaseEvent.find_by(
      event_type: event_type,
      transaction_id: transaction_id,
      project_id: project.id,
      webhook_validated: false
    )

    return event if event

    # Only fall back to original_transaction_id matching for initial purchases.
    # For Apple subscriptions, original_transaction_id is shared across ALL renewals.
    # If we match by original_transaction_id on a DID_RENEW, we'd overwrite the initial
    # purchase event instead of creating a new event for the renewal.
    # Initial purchases have transaction_id == original_transaction_id.
    return nil unless transaction_id.present? && transaction_id == original_transaction_id

    PurchaseEvent.find_by(
      event_type: event_type,
      original_transaction_id: original_transaction_id,
      project_id: project.id,
      webhook_validated: false
    )


  end

  # When a subscription product changes within the same group (upgrade/downgrade),
  # create a cancel event for the old product so stats reflect the transition.
  def cancel_previous_product_on_change(original_transaction_id, new_product_id, project)
    return if original_transaction_id.blank? || new_product_id.blank?

    # Find the most recent BUY for a DIFFERENT product in this subscription group
    old_buy = PurchaseEvent.where(
      original_transaction_id: original_transaction_id,
      event_type: Grovs::Purchases::EVENT_BUY,
      project_id: project.id
    ).where.not(product_id: new_product_id)
     .order(created_at: :desc)
     .first
    return unless old_buy

    # Only cancel if the old product is still "active" (latest event is a BUY).
    # This prevents false cancels when re-subscribing after expiry to a different product.
    latest_for_old = PurchaseEvent.where(
      original_transaction_id: original_transaction_id,
      product_id: old_buy.product_id,
      project_id: project.id
    ).order(created_at: :desc).first
    return unless latest_for_old&.buy?

    cancel_txn_id = "#{old_buy.transaction_id}_product_change_cancel"
    return if PurchaseEvent.exists?(transaction_id: cancel_txn_id, project_id: project.id)

    cancel_event = PurchaseEvent.create!(
      project_id: project.id,
      event_type: Grovs::Purchases::EVENT_CANCEL,
      product_id: old_buy.product_id,
      identifier: old_buy.identifier,
      price_cents: old_buy.price_cents,
      currency: old_buy.currency,
      usd_price_cents: old_buy.usd_price_cents,
      date: Time.current,
      transaction_id: cancel_txn_id,
      original_transaction_id: original_transaction_id,
      webhook_validated: true,
      device_id: old_buy.device_id,
      link_id: old_buy.link_id,
      store: true,
      store_source: Grovs::Webhooks::APPLE,
      purchase_type: Grovs::Purchases::TYPE_SUBSCRIPTION,
      processed: false
    )
    ProcessPurchaseEventJob.perform_async(cancel_event.id)
    @logger.info "Created product-change cancel for #{old_buy.product_id} → #{new_product_id} (txn: #{original_transaction_id})"
  rescue ActiveRecord::RecordNotUnique
    nil
  end
end
