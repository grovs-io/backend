module GoogleIapService::BundleHandler
  extend ActiveSupport::Concern

  private

  # @param line_items [Array<ProductLineItem>] from ProductPurchaseV2.product_line_item
  # @param purchase_token [String] Shared purchase token for the bundle
  # @param order_id [String] Shared order ID for the bundle
  # @param project [Project] The project this purchase belongs to
  # @param package_name [String] App package name (identifier)
  # @return [Array<PurchaseEvent>] Created purchase events
  def handle_bundle_purchase(line_items:, purchase_token:, order_id:, project:, package_name:)
    product_ids = line_items.filter_map { |item| item.product_id.presence }
    catalog = batch_get_product_details(package_name, product_ids)
    events = []

    line_items.each do |item|
      product_id = item.product_id
      next unless product_id.present?

      transaction_id = "#{purchase_token}:#{product_id}"

      product_details = catalog[product_id]
      price = 0
      currency = "USD"
      if product_details.respond_to?(:default_price) && product_details.default_price
        price = IapUtils.convert_google_micros_to_cents(product_details.default_price.price_micros)
        currency = product_details.default_price.currency || currency
      end

      event = handle_google_purchase_event(
        event_type: Grovs::Purchases::EVENT_BUY,
        project: project,
        transaction_id: transaction_id,
        original_transaction_id: purchase_token,
        product_id: product_id,
        identifier: package_name,
        price_cents: price,
        currency: currency,
        date: Time.current,
        purchase_type: Grovs::Purchases::TYPE_ONE_TIME,
        order_id: order_id,
        quantity: extract_v2_line_item_quantity(item)
      )

      events << event if event
    end

    @logger.info "Processed bundle purchase: #{events.size} items for order #{order_id}"
    events
  end

  # Single API call to fetch product details for all bundle items.
  # Falls back to per-item lookups if the batch API fails.
  def batch_get_product_details(package_name, product_ids)
    return {} if product_ids.empty?

    response = @service.batch_inappproduct_get(package_name, sku: product_ids)
    (response&.inappproduct || []).index_by(&:sku)
  rescue Google::Apis::Error => e
    @logger.warn "Batch product lookup failed, falling back to individual: #{e.message}"
    product_ids.index_with do |pid|
      get_product_details(package_name, pid)
    end
  end
end
