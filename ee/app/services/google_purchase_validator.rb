class GooglePurchaseValidator
  class << self
    def validate(event, instance)
      service = build_google_service(instance)
      return false unless service

      package_name = event.identifier
      product_id = event.product_id
      purchase_token = event.transaction_id

      if event.purchase_type == Grovs::Purchases::TYPE_SUBSCRIPTION
        verified = service.get_purchase_subscription(package_name, product_id, purchase_token)
        unless verified
          Rails.logger.error "Google API returned nil subscription for event #{event.id}"
          return false
        end
        update_from_google_subscription(event, verified, package_name, instance)
      elsif event.purchase_type == Grovs::Purchases::TYPE_ONE_TIME
        verified = service.get_purchase_product(package_name, product_id, purchase_token)
        unless verified
          Rails.logger.error "Google API returned nil one-time purchase for event #{event.id}"
          return false
        end
        acknowledge_google_purchase(service, package_name, product_id, purchase_token)
        product_details = fetch_google_product_details(service, package_name, product_id)
        update_from_google_one_time(event, verified, product_details, package_name, instance)
      else
        # purchase_type unknown — try subscription first, fall back to one-time on 404
        begin
          verified = service.get_purchase_subscription(package_name, product_id, purchase_token)
          unless verified
            Rails.logger.error "Google API returned nil subscription (fallback) for event #{event.id}"
            return false
          end
          update_from_google_subscription(event, verified, package_name, instance)
        rescue Google::Apis::ClientError => e
          raise unless e.status_code == 404
          verified = service.get_purchase_product(package_name, product_id, purchase_token)
          unless verified
            Rails.logger.error "Google API returned nil one-time purchase (fallback) for event #{event.id}"
            return false
          end
          acknowledge_google_purchase(service, package_name, product_id, purchase_token)
          product_details = fetch_google_product_details(service, package_name, product_id)
          update_from_google_one_time(event, verified, product_details, package_name, instance)
        end
      end

      true
    rescue Google::Apis::ClientError, Google::Apis::AuthorizationError,
           ArgumentError, NoMethodError => e
      Rails.logger.error "Google validation non-retryable error for event #{event.id}: #{e.class} - #{e.message}"
      false
    end

    def build_google_service(instance)
      service = IapUtils.build_google_service(instance)
      Rails.logger.warn "Missing Google API credentials for instance #{instance.id}" unless service
      service
    end

    private

    def update_from_google_subscription(event, verified, package_name, instance)
      price = IapUtils.convert_google_micros_to_cents(verified.price_amount_micros)
      currency = verified.price_currency_code
      start_date = IapUtils.parse_ms_timestamp(verified.start_time_millis)
      expires_date = IapUtils.extract_google_expires_date(verified)
      original_txn_id = IapUtils.extract_google_original_txn_id(verified, event.transaction_id)

      correct_project = verified.purchase_type == 0 ? instance.test : instance.production

      update_attrs = {
        webhook_validated: true,
        store: true,
        identifier: package_name,
        original_transaction_id: original_txn_id,
        date: start_date,
        expires_date: expires_date,
        price_cents: price,
        currency: currency,
        purchase_type: Grovs::Purchases::TYPE_SUBSCRIPTION
      }
      update_attrs[:project_id] = correct_project.id if correct_project

      event.update!(update_attrs)
    end

    def update_from_google_one_time(event, verified, product_details, package_name, instance)
      start_date = IapUtils.parse_ms_timestamp(verified.purchase_time_millis)

      correct_project = verified.purchase_type == 0 ? instance.test : instance.production

      update_attrs = {
        webhook_validated: true,
        store: true,
        identifier: package_name,
        date: start_date,
        purchase_type: Grovs::Purchases::TYPE_ONE_TIME
      }
      update_attrs[:project_id] = correct_project.id if correct_project

      if (event.price_cents.nil? || event.price_cents == 0) && product_details&.default_price
        update_attrs[:price_cents] = IapUtils.convert_google_micros_to_cents(product_details.default_price.price_micros)
        update_attrs[:currency] = product_details.default_price.currency
      end

      event.update!(update_attrs)
    end

    def acknowledge_google_purchase(service, package_name, product_id, purchase_token)
      service.acknowledge_purchase_product(package_name, product_id, purchase_token)
    rescue Google::Apis::Error => e
      Rails.logger.warn "Google acknowledge failed for #{product_id}: #{e.message}"
    end

    def fetch_google_product_details(service, package_name, product_id)
      IapUtils.fetch_google_product_details(service, package_name, product_id)
    end
  end
end
