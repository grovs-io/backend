module GoogleIapService::OneTimeProductHandler
  extend ActiveSupport::Concern

  private

  def handle_one_time_notification(notification, instance, iap_webhook_message, package_name)
    otp = notification["oneTimeProductNotification"]
    purchase_token = otp["purchaseToken"]
    product_id = otp["sku"]

    unless purchase_token
      @logger.error "Google one-time notification missing purchaseToken"
      return false
    end

    iap_webhook_message.update(notification_type: "ONE_TIME_PRODUCT")

    if product_id.present?
      handle_single_product(purchase_token, product_id, package_name, instance, iap_webhook_message)
    else
      # Bundle purchase — sku not provided in RTDN, use productsv2 API
      handle_bundle_or_unknown(purchase_token, package_name, instance, iap_webhook_message)
    end
  end

  def handle_single_product(purchase_token, product_id, package_name, instance, iap_webhook_message)
    verified_purchase = verify_one_time_purchase(purchase_token, product_id, package_name)
    return false unless verified_purchase

    acknowledge_one_time_purchase(package_name, product_id, purchase_token)

    project = verified_purchase.purchase_type == 0 ? instance.test : instance.production
    return false unless project

    iap_webhook_message.update(project_id: project.id)

    product_details = get_product_details(package_name, product_id)
    create_one_time_purchase_event(verified_purchase, product_details, project, product_id, purchase_token, package_name)
    true
  end

  def verify_one_time_purchase(purchase_token, product_id, package_name)
    @service.get_purchase_product(package_name, product_id, purchase_token)
  rescue Google::Apis::AuthorizationError => e
    @logger.error "Google auth error: #{e.message}"
    nil
  rescue Google::Apis::ClientError => e
    @logger.error "Google client error: #{e.message}"
    nil
  end

  def acknowledge_one_time_purchase(package_name, product_id, purchase_token)
    @service.acknowledge_purchase_product(package_name, product_id, purchase_token)
  rescue Google::Apis::Error => e
    @logger.warn "Google acknowledge failed for #{product_id}: #{e.message}"
  end

  def get_product_details(package_name, product_id)
    IapUtils.fetch_google_product_details(@service, package_name, product_id)
  end

  def handle_bundle_or_unknown(purchase_token, package_name, instance, iap_webhook_message)
    purchase_v2 = fetch_product_purchase_v2(package_name, purchase_token)
    return false unless purchase_v2

    project = determine_project(purchase_v2, instance)
    return false unless project

    iap_webhook_message.update(project_id: project.id)

    # ProductPurchaseV2 uses product_line_item (Array<ProductLineItem>)
    line_items = purchase_v2.respond_to?(:product_line_item) ? purchase_v2.product_line_item : nil

    if line_items && line_items.size > 1
      # Multi-product bundle
      order_id = purchase_v2.respond_to?(:order_id) ? purchase_v2.order_id : nil
      handle_bundle_purchase(line_items: line_items, purchase_token: purchase_token,
                             order_id: order_id, project: project, package_name: package_name)
      true
    elsif line_items && line_items.size == 1
      # Single product via v2 API
      handle_single_product_from_v2(line_items.first, purchase_token, package_name, project, purchase_v2)
      true
    else
      @logger.warn "productsv2 returned no line items for token #{purchase_token}"
      false
    end
  end

  def fetch_product_purchase_v2(package_name, purchase_token)
    @service.getproductpurchasev2_purchase_productsv2(package_name, purchase_token)
  rescue Google::Apis::Error => e
    @logger.error "Google productsv2 API error: #{e.message}"
    nil
  end

  # ProductPurchaseV2 has test_purchase_context (present = test purchase)
  def determine_project(purchase_v2, instance)
    if purchase_v2.respond_to?(:test_purchase_context) && purchase_v2.test_purchase_context
      instance.test
    else
      instance.production
    end
  end

  def handle_single_product_from_v2(item, purchase_token, package_name, project, purchase_v2)
    order_id = purchase_v2.respond_to?(:order_id) ? purchase_v2.order_id : nil
    product_id = item.product_id

    # ProductLineItem has no price fields — fetch from product catalog
    product_details = get_product_details(package_name, product_id)
    price = 0
    currency = "USD"
    if product_details.respond_to?(:default_price) && product_details.default_price
      price = IapUtils.convert_google_micros_to_cents(product_details.default_price.price_micros)
      currency = product_details.default_price.currency || currency
    end

    handle_google_purchase_event(
      event_type: Grovs::Purchases::EVENT_BUY,
      project: project,
      transaction_id: purchase_token,
      original_transaction_id: purchase_token,
      product_id: product_id,
      identifier: package_name,
      price_cents: price,
      currency: currency,
      date: extract_v2_purchase_time(purchase_v2),
      purchase_type: GoogleIapService::RentalSupport.determine_purchase_type(item),
      order_id: order_id,
      quantity: extract_v2_line_item_quantity(item)
    )
  end

  def create_one_time_purchase_event(verified_purchase, product_details, project, product_id, purchase_token, identifier)
    start_date = IapUtils.parse_ms_timestamp(verified_purchase.purchase_time_millis)
    order_id = verified_purchase.respond_to?(:order_id) ? verified_purchase.order_id : nil
    quantity = verified_purchase.respond_to?(:quantity) ? (verified_purchase.quantity || 1) : 1

    price = 0
    currency = "USD"

    if product_details&.default_price
      price = IapUtils.convert_google_micros_to_cents(product_details.default_price.price_micros)
      currency = product_details.default_price.currency || currency
    end

    handle_google_purchase_event(
      event_type: Grovs::Purchases::EVENT_BUY,
      project: project,
      transaction_id: purchase_token,
      original_transaction_id: purchase_token,
      product_id: product_id,
      identifier: identifier,
      price_cents: price,
      currency: currency,
      date: start_date,
      purchase_type: Grovs::Purchases::TYPE_ONE_TIME,
      order_id: order_id,
      quantity: quantity
    )
  end
end
