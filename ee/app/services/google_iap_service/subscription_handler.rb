module GoogleIapService::SubscriptionHandler
  extend ActiveSupport::Concern

  GOOGLE_NOTIFICATION_TYPES = {
    1 => 'SUBSCRIPTION_RECOVERED',
    2 => 'SUBSCRIPTION_RENEWED',
    3 => 'SUBSCRIPTION_CANCELED',
    4 => 'SUBSCRIPTION_PURCHASED',
    5 => 'SUBSCRIPTION_ON_HOLD',
    6 => 'SUBSCRIPTION_IN_GRACE_PERIOD',
    7 => 'SUBSCRIPTION_RESTARTED',
    8 => 'SUBSCRIPTION_PRICE_CHANGE_CONFIRMED', # deprecated
    9 => 'SUBSCRIPTION_DEFERRED',
    10 => 'SUBSCRIPTION_PAUSED',
    11 => 'SUBSCRIPTION_PAUSE_SCHEDULE_CHANGED',
    12 => 'SUBSCRIPTION_REVOKED',
    13 => 'SUBSCRIPTION_EXPIRED',
    19 => 'SUBSCRIPTION_PRICE_CHANGE_UPDATED',
    20 => 'SUBSCRIPTION_PENDING_PURCHASE_CANCELED'
  }.freeze

  private

  # Returns true on success, false on error, :skipped for no-op notification types.
  def handle_subscription_notification(notification, instance, iap_webhook_message, package_name)
    sub = notification["subscriptionNotification"]
    purchase_token = sub["purchaseToken"]
    subscription_id = sub["subscriptionId"]
    notification_type = sub["notificationType"]

    unless purchase_token && subscription_id
      @logger.error "Google subscription notification missing purchaseToken or subscriptionId"
      return false
    end

    iap_webhook_message.update(notification_type: GOOGLE_NOTIFICATION_TYPES[notification_type] || "UNKNOWN")

    verified_purchase = verify_subscription_purchase(purchase_token, subscription_id, package_name)
    return false unless verified_purchase

    project = verified_purchase.purchase_type == 0 ? instance.test : instance.production
    return false unless project

    iap_webhook_message.update(project_id: project.id)

    event_type = map_notification_to_event(notification_type)
    return :skipped unless event_type

    create_or_update_subscription_event(event_type, verified_purchase, project, subscription_id, purchase_token, package_name)
    true
  end

  def verify_subscription_purchase(purchase_token, subscription_id, package_name)
    @service.get_purchase_subscription(package_name, subscription_id, purchase_token)
  rescue Google::Apis::AuthorizationError => e
    @logger.error "Google auth error: #{e.message}"
    nil
  rescue Google::Apis::ClientError => e
    @logger.error "Google client error: #{e.message}"
    nil
  end

  def map_notification_to_event(notification_type)
    case notification_type
    when 1, 2, 4, 7 then Grovs::Purchases::EVENT_BUY    # RECOVERED, RENEWED, PURCHASED, RESTARTED
    when 3, 12, 13, 20 then Grovs::Purchases::EVENT_CANCEL # CANCELED, REVOKED, EXPIRED, PENDING_PURCHASE_CANCELED
    when 5, 6 then nil   # ON_HOLD, IN_GRACE_PERIOD — billing retry, await resolution
    when 9, 10, 11 then nil # DEFERRED, PAUSED, PAUSE_SCHEDULE_CHANGED — no purchase
    when 8, 19 then nil  # price change notifications, no event needed
    else
      @logger.warn "Unhandled notification type: #{notification_type}"
      nil
    end
  end

  def create_or_update_subscription_event(event_type, purchase_data, project, subscription_id, purchase_token, identifier)
    start_date = IapUtils.parse_ms_timestamp(purchase_data.start_time_millis)
    price = IapUtils.convert_google_micros_to_cents(purchase_data.price_amount_micros)
    currency = purchase_data.price_currency_code || "USD"
    expires_date = IapUtils.extract_google_expires_date(purchase_data)
    original_txn_id = IapUtils.extract_google_original_txn_id(purchase_data, purchase_token)
    order_id = purchase_data.respond_to?(:order_id) ? purchase_data.order_id : nil

    handle_google_purchase_event(
      event_type: event_type,
      project: project,
      transaction_id: purchase_token,
      original_transaction_id: original_txn_id,
      product_id: subscription_id,
      identifier: identifier,
      price_cents: price,
      currency: currency,
      date: start_date,
      expires_date: expires_date,
      purchase_type: Grovs::Purchases::TYPE_SUBSCRIPTION,
      order_id: order_id
    )
  end
end
