module IapUtils
  module_function

  # Apple App Store Server API timestamps are always in milliseconds since epoch.
  def parse_ms_timestamp(millis)
    return Time.current unless millis
    Time.at(millis.to_i / 1000)
  end

  # Apple prices are in milliunits (e.g. 9990 = $9.99). Divide by 10 to get cents.
  def convert_apple_price_to_cents(price_milliunits)
    return nil unless price_milliunits
    price_milliunits.to_i / 10
  end

  # Google prices are in micros (e.g. 12_990_000 = $12.99). Divide by 10_000 to get cents.
  def convert_google_micros_to_cents(micros)
    return 0 unless micros
    micros.to_i / 10_000
  end

  def apple_purchase_type(type)
    type.to_s.include?("Subscription") ? Grovs::Purchases::TYPE_SUBSCRIPTION : Grovs::Purchases::TYPE_ONE_TIME
  end

  def build_google_service(instance)
    json_key = PurchaseAttributionService.cached_google_json_key(instance)
    return nil unless json_key

    authorizer = Google::Auth::ServiceAccountCredentials.make_creds(
      json_key_io: StringIO.new(json_key),
      scope: Grovs::GOOGLE_PUBLISHER_SCOPE
    )
    authorizer.fetch_access_token!

    service = Google::Apis::AndroidpublisherV3::AndroidPublisherService.new
    service.authorization = authorizer
    service
  end

  def extract_google_original_txn_id(purchase_data, fallback_token)
    if purchase_data.respond_to?(:order_id) && purchase_data.order_id.present?
      purchase_data.order_id.sub(/\.\d+$/, '')
    else
      fallback_token
    end
  end

  def extract_google_expires_date(purchase_data)
    if purchase_data.respond_to?(:expiry_time_millis) && purchase_data.expiry_time_millis
      Time.at(purchase_data.expiry_time_millis.to_i / 1000)
    end
  end

  # Fetches product details with fallback: tries legacy inappproducts API first,
  # falls back to monetization onetimeproducts API on ClientError.
  def fetch_google_product_details(service, package_name, product_id)
    service.get_inappproduct(package_name, product_id)
  rescue Google::Apis::ClientError
    fetch_google_product_details_from_monetization(service, package_name, product_id)
  rescue Google::Apis::Error => e
    Rails.logger.warn "Could not fetch product details for #{product_id}: #{e.message}"
    nil
  end

  def fetch_google_product_details_from_monetization(service, package_name, product_id)
    Rails.logger.warn "Legacy inappproducts failed for #{product_id}, trying monetization API"
    otp = service.get_monetization_onetimeproduct(package_name, product_id)
    extract_us_price_from_monetization_product(otp)
  rescue Google::Apis::Error => e
    Rails.logger.warn "Monetization API also failed for #{product_id}: #{e.message}"
    nil
  end

  private_class_method :fetch_google_product_details_from_monetization

  # Converts a Google monetization OneTimeProduct to a duck-type compatible object
  # with default_price matching the legacy InAppProduct format (price_micros + currency).
  # Prefers US pricing, falls back to EUR, then any available region (converted to USD).
  def extract_us_price_from_monetization_product(otp)
    return nil unless otp&.purchase_options&.any?

    product_id = otp.respond_to?(:product_id) ? otp.product_id : "unknown"
    all_configs = collect_regional_configs(otp)
    return nil if all_configs.empty?

    # Prefer US, then EUR, then first available
    config = all_configs.find { |c| c.region_code == "US" } ||
             all_configs.find { |c| c.price.currency_code == "EUR" } ||
             all_configs.first

    money = config.price
    price_micros = money_to_micros(money)
    currency = money.currency_code

    if currency != "USD"
      cents = convert_google_micros_to_cents(price_micros)
      usd_cents = CurrencyConversionService.to_usd_cents(cents, currency)
      unless usd_cents
        Rails.logger.warn "Could not convert #{currency} to USD for monetization product #{product_id}"
        return nil
      end
      Rails.logger.info "Converted #{currency} #{cents}c to USD #{usd_cents}c for product #{product_id}"
      price_micros = usd_cents * 10_000
      currency = "USD"
    end

    OpenStruct.new(default_price: OpenStruct.new(price_micros: price_micros, currency: currency))
  end

  def money_to_micros(money)
    (money.units.to_i * 1_000_000) + (money.nanos.to_i / 1_000)
  end

  private_class_method :money_to_micros

  def collect_regional_configs(otp)
    otp.purchase_options.flat_map do |option|
      (option.regional_pricing_and_availability_configs || []).select(&:price)
    end
  end

  private_class_method :collect_regional_configs
end
