class ApplePurchaseValidator
  class << self
    def validate(event, instance)
      client = build_apple_client(event, instance)
      return false unless client

      response = client.get_transaction_info(event.transaction_id)
      signed_tx = response["signedTransactionInfo"]
      unless signed_tx
        Rails.logger.error "Apple API response missing signedTransactionInfo for event #{event.id}"
        return false
      end

      transaction = AppStoreServerApi::Utils::Decoder.decode_jws!(signed_tx)
      unless transaction
        Rails.logger.error "Apple transaction decode returned nil for event #{event.id}"
        return false
      end

      update_from_apple(event, transaction)
      true
    rescue JWT::DecodeError, OpenSSL::OpenSSLError, JSON::ParserError,
           ArgumentError, NoMethodError => e
      Rails.logger.error "Apple validation non-retryable error for event #{event.id}: #{e.class} - #{e.message}"
      false
    end

    def build_apple_client(event, instance)
      api_key = instance.ios_application&.configuration&.ios_server_api_key
      bundle_id = instance.ios_application&.configuration&.bundle_id

      unless api_key&.private_key && api_key.key_id && api_key.issuer_id && bundle_id
        Rails.logger.warn "Missing Apple API credentials for instance #{instance.id}"
        return nil
      end

      environment = event.project.test? ? :sandbox : :production

      AppStoreServerApi::Client.new(
        private_key: api_key.private_key,
        key_id: api_key.key_id,
        issuer_id: api_key.issuer_id,
        bundle_id: bundle_id,
        environment: environment
      )
    end

    private

    def update_from_apple(event, transaction)
      price_cents = IapUtils.convert_apple_price_to_cents(transaction["price"])
      currency = transaction["currency"]
      purchase_date = IapUtils.parse_ms_timestamp(transaction["purchaseDate"])
      purchase_type = IapUtils.apple_purchase_type(transaction["type"])

      update_attrs = {
        webhook_validated: true,
        store: true,
        identifier: transaction["bundleId"],
        original_transaction_id: transaction["originalTransactionId"],
        product_id: transaction["productId"],
        date: purchase_date,
        purchase_type: purchase_type
      }

      if purchase_type == Grovs::Purchases::TYPE_SUBSCRIPTION || event.price_cents.nil? || event.price_cents == 0
        update_attrs[:price_cents] = price_cents
        update_attrs[:currency] = currency
      end

      event.update!(update_attrs)
    end
  end
end
