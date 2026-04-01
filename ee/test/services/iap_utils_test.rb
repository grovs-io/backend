require "test_helper"

class IapUtilsTest < ActiveSupport::TestCase
  # --- parse_ms_timestamp ---

  test "parse_ms_timestamp converts milliseconds to Time" do
    result = IapUtils.parse_ms_timestamp(1_735_689_600_000)
    assert_equal Time.at(1_735_689_600), result
  end

  test "parse_ms_timestamp returns Time.current for nil" do
    freeze_time do
      result = IapUtils.parse_ms_timestamp(nil)
      assert_equal Time.current, result
    end
  end

  test "parse_ms_timestamp handles string input" do
    result = IapUtils.parse_ms_timestamp("1735689600000")
    assert_equal Time.at(1_735_689_600), result
  end

  # --- convert_apple_price_to_cents ---

  test "convert_apple_price_to_cents converts milliunits to cents" do
    assert_equal 999, IapUtils.convert_apple_price_to_cents(9990)
    assert_equal 129, IapUtils.convert_apple_price_to_cents(1299)
  end

  test "convert_apple_price_to_cents returns nil for nil" do
    assert_nil IapUtils.convert_apple_price_to_cents(nil)
  end

  test "convert_apple_price_to_cents returns 0 for zero" do
    assert_equal 0, IapUtils.convert_apple_price_to_cents(0)
  end

  # --- convert_google_micros_to_cents ---

  test "convert_google_micros_to_cents converts micros to cents" do
    assert_equal 1299, IapUtils.convert_google_micros_to_cents(12_990_000)
    assert_equal 499, IapUtils.convert_google_micros_to_cents(4_990_000)
  end

  test "convert_google_micros_to_cents returns 0 for nil" do
    assert_equal 0, IapUtils.convert_google_micros_to_cents(nil)
  end

  test "convert_google_micros_to_cents returns 0 for zero" do
    assert_equal 0, IapUtils.convert_google_micros_to_cents(0)
  end

  # --- apple_purchase_type ---

  test "apple_purchase_type returns subscription for Auto-Renewable Subscription" do
    assert_equal Grovs::Purchases::TYPE_SUBSCRIPTION, IapUtils.apple_purchase_type("Auto-Renewable Subscription")
  end

  test "apple_purchase_type returns subscription for Non-Renewing Subscription" do
    assert_equal Grovs::Purchases::TYPE_SUBSCRIPTION, IapUtils.apple_purchase_type("Non-Renewing Subscription")
  end

  test "apple_purchase_type returns one_time for Consumable" do
    assert_equal Grovs::Purchases::TYPE_ONE_TIME, IapUtils.apple_purchase_type("Consumable")
  end

  test "apple_purchase_type returns one_time for nil" do
    assert_equal Grovs::Purchases::TYPE_ONE_TIME, IapUtils.apple_purchase_type(nil)
  end

  # --- extract_google_original_txn_id ---

  test "extract_google_original_txn_id strips .N suffix from order_id" do
    purchase = OpenStruct.new(order_id: "GPA.3345-3232.5")
    assert_equal "GPA.3345-3232", IapUtils.extract_google_original_txn_id(purchase, "fallback")
  end

  test "extract_google_original_txn_id uses order_id without suffix as-is" do
    purchase = OpenStruct.new(order_id: "GPA.3345-3232")
    assert_equal "GPA.3345-3232", IapUtils.extract_google_original_txn_id(purchase, "fallback")
  end

  test "extract_google_original_txn_id falls back when order_id is nil" do
    purchase = OpenStruct.new(order_id: nil)
    assert_equal "fallback_token", IapUtils.extract_google_original_txn_id(purchase, "fallback_token")
  end

  test "extract_google_original_txn_id falls back when order_id is blank" do
    purchase = OpenStruct.new(order_id: "")
    assert_equal "fallback_token", IapUtils.extract_google_original_txn_id(purchase, "fallback_token")
  end

  # --- extract_google_expires_date ---

  test "extract_google_expires_date converts millis to Time" do
    purchase = OpenStruct.new(expiry_time_millis: 1_738_368_000_000)
    assert_equal Time.at(1_738_368_000), IapUtils.extract_google_expires_date(purchase)
  end

  test "extract_google_expires_date returns nil when expiry_time_millis is nil" do
    purchase = OpenStruct.new(expiry_time_millis: nil)
    assert_nil IapUtils.extract_google_expires_date(purchase)
  end

  test "extract_google_expires_date returns nil when not responsive" do
    purchase = Object.new
    assert_nil IapUtils.extract_google_expires_date(purchase)
  end

  # --- extract_us_price_from_monetization_product ---

  test "extract_us_price_from_monetization_product returns price from US region" do
    otp = build_monetization_product(us_units: 3, us_nanos: 490_000_000, us_currency: "USD")
    result = IapUtils.extract_us_price_from_monetization_product(otp)

    assert result
    assert_equal 3_490_000, result.default_price.price_micros
    assert_equal "USD", result.default_price.currency
  end

  test "extract_us_price_from_monetization_product converts to cents correctly" do
    otp = build_monetization_product(us_units: 12, us_nanos: 990_000_000, us_currency: "USD")
    result = IapUtils.extract_us_price_from_monetization_product(otp)

    assert_equal 1299, IapUtils.convert_google_micros_to_cents(result.default_price.price_micros)
  end

  test "extract_us_price_from_monetization_product handles whole dollar amount with zero nanos" do
    otp = build_monetization_product(us_units: 5, us_nanos: 0, us_currency: "USD")
    result = IapUtils.extract_us_price_from_monetization_product(otp)

    assert_equal 5_000_000, result.default_price.price_micros
    assert_equal 500, IapUtils.convert_google_micros_to_cents(result.default_price.price_micros)
  end

  test "extract_us_price_from_monetization_product prefers EUR when no US region" do
    eur_config = OpenStruct.new(region_code: "DE", price: OpenStruct.new(units: 3, nanos: 490_000_000, currency_code: "EUR"))
    gb_config = OpenStruct.new(region_code: "GB", price: OpenStruct.new(units: 2, nanos: 990_000_000, currency_code: "GBP"))
    option = OpenStruct.new(regional_pricing_and_availability_configs: [gb_config, eur_config])
    otp = OpenStruct.new(purchase_options: [option])

    CurrencyConversionService.stub(:to_usd_cents, 380) do
      result = IapUtils.extract_us_price_from_monetization_product(otp)
      assert result
      assert_equal "USD", result.default_price.currency
      assert_equal 3_800_000, result.default_price.price_micros
    end
  end

  test "extract_us_price_from_monetization_product falls back to any region when no US or EUR" do
    gb_config = OpenStruct.new(region_code: "GB", price: OpenStruct.new(units: 2, nanos: 990_000_000, currency_code: "GBP"))
    option = OpenStruct.new(regional_pricing_and_availability_configs: [gb_config])
    otp = OpenStruct.new(purchase_options: [option])

    CurrencyConversionService.stub(:to_usd_cents, 370) do
      result = IapUtils.extract_us_price_from_monetization_product(otp)
      assert result
      assert_equal "USD", result.default_price.currency
      assert_equal 3_700_000, result.default_price.price_micros
    end
  end

  test "extract_us_price_from_monetization_product returns nil when currency conversion fails" do
    gb_config = OpenStruct.new(region_code: "GB", price: OpenStruct.new(units: 2, nanos: 990_000_000, currency_code: "GBP"))
    option = OpenStruct.new(regional_pricing_and_availability_configs: [gb_config])
    otp = OpenStruct.new(purchase_options: [option])

    CurrencyConversionService.stub(:to_usd_cents, nil) do
      result = IapUtils.extract_us_price_from_monetization_product(otp)
      assert_nil result
    end
  end

  test "extract_us_price_from_monetization_product returns nil for nil input" do
    assert_nil IapUtils.extract_us_price_from_monetization_product(nil)
  end

  test "extract_us_price_from_monetization_product returns nil for empty purchase_options" do
    otp = OpenStruct.new(purchase_options: [])
    assert_nil IapUtils.extract_us_price_from_monetization_product(otp)
  end

  test "extract_us_price_from_monetization_product returns nil when configs are nil" do
    option = OpenStruct.new(regional_pricing_and_availability_configs: nil)
    otp = OpenStruct.new(purchase_options: [option])

    assert_nil IapUtils.extract_us_price_from_monetization_product(otp)
  end

  # 1. US region with non-USD currency triggers conversion
  test "extract_us_price_from_monetization_product converts non-USD US region price to USD" do
    us_config = OpenStruct.new(region_code: "US", price: OpenStruct.new(units: 3, nanos: 490_000_000, currency_code: "EUR"))
    option = OpenStruct.new(regional_pricing_and_availability_configs: [us_config])
    otp = OpenStruct.new(purchase_options: [option])

    CurrencyConversionService.stub(:to_usd_cents, 400) do
      result = IapUtils.extract_us_price_from_monetization_product(otp)
      assert result
      assert_equal "USD", result.default_price.currency
      assert_equal 4_000_000, result.default_price.price_micros
    end
  end

  # 2. US config in second purchase_option found via flat_map
  test "extract_us_price_from_monetization_product finds US config across multiple purchase_options" do
    gb_config = OpenStruct.new(region_code: "GB", price: OpenStruct.new(units: 2, nanos: 990_000_000, currency_code: "GBP"))
    option1 = OpenStruct.new(regional_pricing_and_availability_configs: [gb_config])

    us_config = OpenStruct.new(region_code: "US", price: OpenStruct.new(units: 4, nanos: 990_000_000, currency_code: "USD"))
    option2 = OpenStruct.new(regional_pricing_and_availability_configs: [us_config])

    otp = OpenStruct.new(purchase_options: [option1, option2])
    result = IapUtils.extract_us_price_from_monetization_product(otp)

    assert result
    assert_equal 4_990_000, result.default_price.price_micros
    assert_equal "USD", result.default_price.currency
  end

  # 6. Mixed configs with some nil prices are filtered out
  test "extract_us_price_from_monetization_product skips configs with nil price" do
    nil_config = OpenStruct.new(region_code: "US", price: nil)
    gb_config = OpenStruct.new(region_code: "GB", price: OpenStruct.new(units: 2, nanos: 990_000_000, currency_code: "GBP"))
    option = OpenStruct.new(regional_pricing_and_availability_configs: [nil_config, gb_config])
    otp = OpenStruct.new(purchase_options: [option])

    CurrencyConversionService.stub(:to_usd_cents, 370) do
      result = IapUtils.extract_us_price_from_monetization_product(otp)
      assert result
      assert_equal "USD", result.default_price.currency
    end
  end

  # --- fetch_google_product_details ---

  test "fetch_google_product_details returns legacy product when inappproducts succeeds" do
    legacy_product = OpenStruct.new(default_price: OpenStruct.new(price_micros: 4_990_000, currency: "GBP"))
    service = Object.new
    service.define_singleton_method(:get_inappproduct) { |*_| legacy_product }

    result = IapUtils.fetch_google_product_details(service, "com.test.app", "gems_500")
    assert_equal legacy_product, result
  end

  test "fetch_google_product_details falls back to monetization API on ClientError" do
    monetization_product = build_monetization_product(us_units: 9, us_nanos: 990_000_000, us_currency: "USD")

    service = Object.new
    service.define_singleton_method(:get_inappproduct) do |*_|
      raise Google::Apis::ClientError.new("must use OneTimeProductsService", status_code: 400)
    end
    service.define_singleton_method(:get_monetization_onetimeproduct) { |*_| monetization_product }

    result = IapUtils.fetch_google_product_details(service, "com.test.app", "gems_500")
    assert_equal 9_990_000, result.default_price.price_micros
    assert_equal "USD", result.default_price.currency
  end

  test "fetch_google_product_details returns nil when both APIs fail" do
    service = Object.new
    service.define_singleton_method(:get_inappproduct) do |*_|
      raise Google::Apis::ClientError.new("must use OneTimeProductsService", status_code: 400)
    end
    service.define_singleton_method(:get_monetization_onetimeproduct) do |*_|
      raise Google::Apis::ClientError.new("not found", status_code: 404)
    end

    result = IapUtils.fetch_google_product_details(service, "com.test.app", "gems_500")
    assert_nil result
  end

  # 3. Monetization API succeeds but returns unusable product (empty purchase_options)
  test "fetch_google_product_details returns nil when monetization succeeds but product has no pricing" do
    empty_product = OpenStruct.new(purchase_options: [])

    service = Object.new
    service.define_singleton_method(:get_inappproduct) do |*_|
      raise Google::Apis::ClientError.new("must use OneTimeProductsService", status_code: 400)
    end
    service.define_singleton_method(:get_monetization_onetimeproduct) { |*_| empty_product }

    result = IapUtils.fetch_google_product_details(service, "com.test.app", "gems_500")
    assert_nil result
  end

  # 5. AuthorizationError doesn't trigger monetization fallback
  test "fetch_google_product_details returns nil on AuthorizationError without trying monetization" do
    service = Object.new
    monetization_called = false
    service.define_singleton_method(:get_inappproduct) do |*_|
      raise Google::Apis::AuthorizationError, "forbidden"
    end
    service.define_singleton_method(:get_monetization_onetimeproduct) do |*_|
      monetization_called = true
    end

    result = IapUtils.fetch_google_product_details(service, "com.test.app", "gems_500")
    assert_nil result
    assert_not monetization_called, "Should not try monetization API on AuthorizationError"
  end

  test "fetch_google_product_details returns nil on ServerError without trying monetization" do
    service = Object.new
    monetization_called = false
    service.define_singleton_method(:get_inappproduct) do |*_|
      raise Google::Apis::ServerError, "internal error"
    end
    service.define_singleton_method(:get_monetization_onetimeproduct) do |*_|
      monetization_called = true
    end

    result = IapUtils.fetch_google_product_details(service, "com.test.app", "gems_500")
    assert_nil result
    assert_not monetization_called, "Should not try monetization API on ServerError"
  end

  private

  def build_monetization_product(us_units:, us_nanos:, us_currency:)
    us_price = OpenStruct.new(units: us_units, nanos: us_nanos, currency_code: us_currency)
    us_config = OpenStruct.new(region_code: "US", price: us_price)
    gb_config = OpenStruct.new(region_code: "GB", price: OpenStruct.new(units: 2, nanos: 990_000_000, currency_code: "GBP"))
    option = OpenStruct.new(regional_pricing_and_availability_configs: [gb_config, us_config])
    OpenStruct.new(purchase_options: [option])
  end
end
