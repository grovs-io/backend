module AppleIapService::SubscriptionHandler
  extend ActiveSupport::Concern

  private

  # Handle SUBSCRIBED notification - maps to BUY
  def handle_subscribed_event(subtype, subscription_info, project)
    handle_subscription_event_type(Grovs::Purchases::EVENT_BUY, subscription_info, project)
  end

  # Handle DID_CHANGE_RENEWAL_PREF notification
  def handle_renewal_preference_change(subtype, subscription_info, project)
    case subtype
    when 'UPGRADE'
      # Upgrade takes effect immediately - cancel old, buy new
      revoke_old_subscription_enable_new_one('UPGRADE', subtype, subscription_info, project)
    when 'DOWNGRADE'
      # Downgrade takes effect at next renewal — actual purchase happens on DID_RENEW
      @logger.info "Downgrade scheduled for transaction: #{subscription_info[:transaction_id]}"
    else
      @logger.info "Renewal preference changed: #{subtype}"
    end
  end

  # Handle DID_CHANGE_RENEWAL_STATUS notification
  # AUTO_RENEW_DISABLED = user turned off auto-renew, but subscription is still active
  # until the end of the current period. The EXPIRED notification handles the actual cancellation.
  def handle_renewal_status_change(subtype, subscription_info, project)
    case subtype
    when 'AUTO_RENEW_DISABLED'
      @logger.info "Auto-renew disabled for transaction: #{subscription_info[:transaction_id]} — no cancel event, awaiting EXPIRED"
    when 'AUTO_RENEW_ENABLED'
      @logger.info "Auto-renew enabled for transaction: #{subscription_info[:transaction_id]}"
    else
      @logger.info "Renewal status changed: #{subtype}"
    end
  end

  # Handle DID_RENEW notification - maps to BUY
  def handle_renewal_event(subtype, subscription_info, project)
    handle_subscription_event_type(Grovs::Purchases::EVENT_BUY, subscription_info, project)
  end

  # Handle DID_FAIL_TO_RENEW notification
  # GRACE_PERIOD subtype = billing retry in progress, subscription still active → no-op
  # Without subtype or BILLING_RETRY = final failure → CANCEL
  def handle_renewal_failure(subtype, subscription_info, project)
    case subtype
    when 'GRACE_PERIOD', 'BILLING_RETRY'
      @logger.info "Renewal failed with #{subtype} for transaction: #{subscription_info[:transaction_id]} — awaiting resolution"
    else
      handle_subscription_event_type(Grovs::Purchases::EVENT_CANCEL, subscription_info, project)
    end
  end

  # Handle EXPIRED notification - maps to CANCEL
  def handle_expiration_event(subtype, subscription_info, project)
    handle_subscription_event_type(Grovs::Purchases::EVENT_CANCEL, subscription_info, project)
  end

  # Handle GRACE_PERIOD_EXPIRED notification - maps to CANCEL
  def handle_grace_period_expired(subscription_info, project)
    handle_subscription_event_type(Grovs::Purchases::EVENT_CANCEL, subscription_info, project)
  end

  # Handle REVOKE notification - maps to CANCEL
  def handle_revoke_event(subscription_info, project)
    handle_subscription_event_type(Grovs::Purchases::EVENT_CANCEL, subscription_info, project)
  end

  # Handle OFFER_REDEEMED notification - route by subtype
  def handle_offer_redeemed(subtype, subscription_info, project)
    case subtype
    when 'UPGRADE'
      revoke_old_subscription_enable_new_one('OFFER_REDEEMED', subtype, subscription_info, project)
    when 'DOWNGRADE'
      @logger.info "Offer redeemed for downgrade on #{subscription_info[:product_id]}, takes effect at next renewal"
    else
      handle_subscription_event_type(Grovs::Purchases::EVENT_BUY, subscription_info, project)
    end
  end

  # Handle ONE_TIME_CHARGE notification - maps to BUY
  def handle_one_time_charge(subscription_info, project)
    handle_subscription_event_type(Grovs::Purchases::EVENT_BUY, subscription_info, project)
  end

  def revoke_old_subscription_enable_new_one(type, subtype, subscription_info, project)
    original_transaction_id = subscription_info[:original_transaction_id]

    # Try subscription_states first (cold-storage-safe), fall back to purchase_events
    old_purchase_event = PurchaseEvent.find_by(original_transaction_id: original_transaction_id, project_id: project.id)
    unless old_purchase_event
      state = SubscriptionState.find_by(original_transaction_id: original_transaction_id, project_id: project.id)
      if state
        old_purchase_event = PurchaseEvent.find_by(transaction_id: state.latest_transaction_id, project_id: project.id)
      end
    end

    if old_purchase_event
      cancel_txn_id = "#{old_purchase_event.transaction_id}_upgrade_cancel"

      unless PurchaseEvent.exists?(transaction_id: cancel_txn_id, project_id: project.id)
        cancel_event = old_purchase_event.dup
        cancel_event.event_type = Grovs::Purchases::EVENT_CANCEL
        cancel_event.transaction_id = cancel_txn_id
        cancel_event.date = Time.current
        cancel_event.webhook_validated = true
        cancel_event.purchase_type = Grovs::Purchases::TYPE_SUBSCRIPTION
        cancel_event.processed = false
        cancel_event.store_source = Grovs::Webhooks::APPLE
        begin
          cancel_event.save!
          ProcessPurchaseEventJob.perform_async(cancel_event.id)
          @logger.info "Created upgrade cancellation event for transaction: #{original_transaction_id}"
        rescue ActiveRecord::RecordNotUnique
          @logger.info "Upgrade cancellation already exists for transaction: #{original_transaction_id}"
        end
      end
    end

    # Create the new subscription event
    handle_subscription_event_type(Grovs::Purchases::EVENT_BUY, subscription_info, project)
  end
end
