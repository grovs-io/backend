require "test_helper"

class GooglePurchaseValidatorTest < ActiveSupport::TestCase
  fixtures :instances, :projects, :devices, :visitors, :purchase_events

  setup do
    @instance = instances(:one)
    @project = projects(:one)
    @test_project = projects(:one_test)
  end

  # --- validate: guard clauses ---

  test "validate returns false when build_google_service returns nil" do
    event = create_event(transaction_id: "txn_no_service")

    GooglePurchaseValidator.stub(:build_google_service, nil) do
      assert_not GooglePurchaseValidator.validate(event, @instance)
    end

    event.reload
    assert_not event.webhook_validated?
  end

  test "validate returns false when subscription API returns nil" do
    event = create_event(
      transaction_id: "txn_sub_nil",
      purchase_type: Grovs::Purchases::TYPE_SUBSCRIPTION
    )

    fake_service = Minitest::Mock.new
    fake_service.expect(:get_purchase_subscription, nil, [event.identifier, event.product_id, event.transaction_id])

    GooglePurchaseValidator.stub(:build_google_service, fake_service) do
      assert_not GooglePurchaseValidator.validate(event, @instance)
    end

    fake_service.verify
  end

  test "validate returns false when one-time API returns nil" do
    event = create_event(
      transaction_id: "txn_ot_nil",
      purchase_type: Grovs::Purchases::TYPE_ONE_TIME
    )

    fake_service = Minitest::Mock.new
    fake_service.expect(:get_purchase_product, nil, [event.identifier, event.product_id, event.transaction_id])

    GooglePurchaseValidator.stub(:build_google_service, fake_service) do
      assert_not GooglePurchaseValidator.validate(event, @instance)
    end

    fake_service.verify
  end

  # --- validate: error handling ---

  test "validate returns false on Google::Apis::AuthorizationError" do
    event = create_event(transaction_id: "txn_auth_err")

    fake_service = Object.new
    fake_service.define_singleton_method(:get_purchase_subscription) { |*_| raise Google::Apis::AuthorizationError, "forbidden" }

    GooglePurchaseValidator.stub(:build_google_service, fake_service) do
      assert_not GooglePurchaseValidator.validate(event, @instance)
    end
  end

  test "validate returns false on non-404 Google::Apis::ClientError" do
    event = create_event(
      transaction_id: "txn_client_err",
      purchase_type: Grovs::Purchases::TYPE_SUBSCRIPTION
    )

    fake_service = Object.new
    fake_service.define_singleton_method(:get_purchase_subscription) { |*_| raise Google::Apis::ClientError.new("bad request", status_code: 400) }

    GooglePurchaseValidator.stub(:build_google_service, fake_service) do
      assert_not GooglePurchaseValidator.validate(event, @instance)
    end
  end

  # --- validate: subscription flow ---

  test "validate updates subscription event with price, expiry, and original_txn_id" do
    event = create_event(
      transaction_id: "txn_goog_sub",
      purchase_type: Grovs::Purchases::TYPE_SUBSCRIPTION
    )

    verified = OpenStruct.new(
      purchase_type: 1,
      price_amount_micros: 12_990_000,
      price_currency_code: "EUR",
      start_time_millis: 1_735_689_600_000,
      expiry_time_millis: 1_738_368_000_000,
      order_id: "GPA.3345-3232.5"
    )

    fake_service = Minitest::Mock.new
    fake_service.expect(:get_purchase_subscription, verified, [event.identifier, event.product_id, event.transaction_id])

    GooglePurchaseValidator.stub(:build_google_service, fake_service) do
      assert GooglePurchaseValidator.validate(event, @instance)
    end

    event.reload
    assert event.webhook_validated?
    assert event.store?
    assert_equal 1299, event.price_cents
    assert_equal "EUR", event.currency
    assert_equal "GPA.3345-3232", event.original_transaction_id
    assert_equal Time.at(1_738_368_000), event.expires_date
    assert_equal Time.at(1_735_689_600), event.date
    assert_equal Grovs::Purchases::TYPE_SUBSCRIPTION, event.purchase_type
    fake_service.verify
  end

  test "validate strips .N suffix from order_id" do
    event = create_event(transaction_id: "txn_strip_suffix")

    verified = OpenStruct.new(
      purchase_type: 1,
      price_amount_micros: 0,
      price_currency_code: "USD",
      start_time_millis: 1_735_689_600_000,
      expiry_time_millis: nil,
      order_id: "GPA.1234-5678.12"
    )

    fake_service = Minitest::Mock.new
    fake_service.expect(:get_purchase_subscription, verified, [event.identifier, event.product_id, event.transaction_id])

    GooglePurchaseValidator.stub(:build_google_service, fake_service) do
      GooglePurchaseValidator.validate(event, @instance)
    end

    event.reload
    assert_equal "GPA.1234-5678", event.original_transaction_id
  end

  test "validate falls back to transaction_id when order_id is nil" do
    event = create_event(transaction_id: "txn_nil_order")

    verified = OpenStruct.new(
      purchase_type: 1,
      price_amount_micros: 0,
      price_currency_code: "USD",
      start_time_millis: 1_735_689_600_000,
      expiry_time_millis: nil,
      order_id: nil
    )

    fake_service = Minitest::Mock.new
    fake_service.expect(:get_purchase_subscription, verified, [event.identifier, event.product_id, event.transaction_id])

    GooglePurchaseValidator.stub(:build_google_service, fake_service) do
      GooglePurchaseValidator.validate(event, @instance)
    end

    event.reload
    assert_equal "txn_nil_order", event.original_transaction_id
  end

  # --- validate: one-time flow ---

  test "validate updates one-time event with product details price" do
    event = create_event(
      transaction_id: "txn_goog_ot",
      purchase_type: Grovs::Purchases::TYPE_ONE_TIME
    )

    verified = OpenStruct.new(
      purchase_type: 1,
      purchase_time_millis: 1_735_689_600_000
    )

    product_details = OpenStruct.new(
      default_price: OpenStruct.new(price_micros: 4_990_000, currency: "GBP")
    )

    fake_service = Minitest::Mock.new
    fake_service.expect(:get_purchase_product, verified, [event.identifier, event.product_id, event.transaction_id])
    fake_service.expect(:acknowledge_purchase_product, nil, [event.identifier, event.product_id, event.transaction_id])
    fake_service.expect(:get_inappproduct, product_details, [event.identifier, event.product_id])

    GooglePurchaseValidator.stub(:build_google_service, fake_service) do
      assert GooglePurchaseValidator.validate(event, @instance)
    end

    event.reload
    assert event.webhook_validated?
    assert_equal 499, event.price_cents
    assert_equal "GBP", event.currency
    assert_equal Grovs::Purchases::TYPE_ONE_TIME, event.purchase_type
    assert_nil event.expires_date
    fake_service.verify
  end

  test "validate one-time with nil product_details leaves price at 0" do
    event = create_event(
      transaction_id: "txn_goog_ot_no_details",
      purchase_type: Grovs::Purchases::TYPE_ONE_TIME
    )

    verified = OpenStruct.new(
      purchase_type: 1,
      purchase_time_millis: 1_735_689_600_000
    )

    fake_service = Minitest::Mock.new
    fake_service.expect(:get_purchase_product, verified, [event.identifier, event.product_id, event.transaction_id])
    fake_service.expect(:acknowledge_purchase_product, nil, [event.identifier, event.product_id, event.transaction_id])
    fake_service.expect(:get_inappproduct, nil, [event.identifier, event.product_id])

    GooglePurchaseValidator.stub(:build_google_service, fake_service) do
      GooglePurchaseValidator.validate(event, @instance)
    end

    event.reload
    assert event.webhook_validated?
    assert_equal 0, event.price_cents
    fake_service.verify
  end

  test "validate one-time preserves existing non-zero price" do
    event = create_event(
      transaction_id: "txn_goog_ot_keep_price",
      price_cents: 1299,
      purchase_type: Grovs::Purchases::TYPE_ONE_TIME
    )

    verified = OpenStruct.new(
      purchase_type: 1,
      purchase_time_millis: 1_735_689_600_000
    )

    product_details = OpenStruct.new(
      default_price: OpenStruct.new(price_micros: 4_990_000, currency: "GBP")
    )

    fake_service = Minitest::Mock.new
    fake_service.expect(:get_purchase_product, verified, [event.identifier, event.product_id, event.transaction_id])
    fake_service.expect(:acknowledge_purchase_product, nil, [event.identifier, event.product_id, event.transaction_id])
    fake_service.expect(:get_inappproduct, product_details, [event.identifier, event.product_id])

    GooglePurchaseValidator.stub(:build_google_service, fake_service) do
      GooglePurchaseValidator.validate(event, @instance)
    end

    event.reload
    # Should keep original price since it was non-zero
    assert_equal 1299, event.price_cents
  end

  # --- validate: one-time monetization API fallback ---

  test "validate one-time falls back to monetization API when legacy fails" do
    event = create_event(
      transaction_id: "txn_monetization_fallback",
      purchase_type: Grovs::Purchases::TYPE_ONE_TIME
    )

    verified = OpenStruct.new(
      purchase_type: 1,
      purchase_time_millis: 1_735_689_600_000
    )

    us_price = OpenStruct.new(units: 9, nanos: 990_000_000, currency_code: "USD")
    us_config = OpenStruct.new(region_code: "US", price: us_price)
    option = OpenStruct.new(regional_pricing_and_availability_configs: [us_config])
    monetization_product = OpenStruct.new(purchase_options: [option])

    fake_service = Object.new
    fake_service.define_singleton_method(:get_purchase_product) { |*_| verified }
    fake_service.define_singleton_method(:acknowledge_purchase_product) { |*_| nil }
    fake_service.define_singleton_method(:get_inappproduct) do |*_|
      raise Google::Apis::ClientError.new("must use OneTimeProductsService", status_code: 400)
    end
    fake_service.define_singleton_method(:get_monetization_onetimeproduct) { |*_| monetization_product }

    GooglePurchaseValidator.stub(:build_google_service, fake_service) do
      assert GooglePurchaseValidator.validate(event, @instance)
    end

    event.reload
    assert event.webhook_validated?
    assert_equal 999, event.price_cents
    assert_equal "USD", event.currency
  end

  test "validate one-time leaves price 0 when both APIs fail" do
    event = create_event(
      transaction_id: "txn_both_apis_fail",
      purchase_type: Grovs::Purchases::TYPE_ONE_TIME
    )

    verified = OpenStruct.new(
      purchase_type: 1,
      purchase_time_millis: 1_735_689_600_000
    )

    fake_service = Object.new
    fake_service.define_singleton_method(:get_purchase_product) { |*_| verified }
    fake_service.define_singleton_method(:acknowledge_purchase_product) { |*_| nil }
    fake_service.define_singleton_method(:get_inappproduct) do |*_|
      raise Google::Apis::ClientError.new("must use OneTimeProductsService", status_code: 400)
    end
    fake_service.define_singleton_method(:get_monetization_onetimeproduct) do |*_|
      raise Google::Apis::ServerError, "internal error"
    end

    GooglePurchaseValidator.stub(:build_google_service, fake_service) do
      assert GooglePurchaseValidator.validate(event, @instance)
    end

    event.reload
    assert event.webhook_validated?
    assert_equal 0, event.price_cents
  end

  # 4. nil purchase_type → sub 404 → one-time → legacy ClientError → monetization API
  test "validate nil purchase_type falls through sub 404 to one-time with monetization fallback" do
    event = create_event(
      transaction_id: "txn_deep_fallback",
      purchase_type: nil
    )

    verified_ot = OpenStruct.new(
      purchase_type: 1,
      purchase_time_millis: 1_735_689_600_000
    )

    us_price = OpenStruct.new(units: 5, nanos: 990_000_000, currency_code: "USD")
    us_config = OpenStruct.new(region_code: "US", price: us_price)
    option = OpenStruct.new(regional_pricing_and_availability_configs: [us_config])
    monetization_product = OpenStruct.new(purchase_options: [option])

    not_found = Google::Apis::ClientError.new("Not Found", status_code: 404)

    fake_service = Object.new
    fake_service.define_singleton_method(:get_purchase_subscription) { |*_| raise not_found }
    fake_service.define_singleton_method(:get_purchase_product) { |*_| verified_ot }
    fake_service.define_singleton_method(:acknowledge_purchase_product) { |*_| nil }
    fake_service.define_singleton_method(:get_inappproduct) do |*_|
      raise Google::Apis::ClientError.new("must use OneTimeProductsService", status_code: 400)
    end
    fake_service.define_singleton_method(:get_monetization_onetimeproduct) { |*_| monetization_product }

    GooglePurchaseValidator.stub(:build_google_service, fake_service) do
      assert GooglePurchaseValidator.validate(event, @instance)
    end

    event.reload
    assert event.webhook_validated?
    assert_equal 599, event.price_cents
    assert_equal "USD", event.currency
    assert_equal Grovs::Purchases::TYPE_ONE_TIME, event.purchase_type
  end

  # --- validate: unknown purchase_type fallback ---

  test "validate with nil purchase_type tries subscription then falls back to one-time on 404" do
    event = create_event(
      transaction_id: "txn_goog_fallback",
      purchase_type: nil
    )

    verified_ot = OpenStruct.new(
      purchase_type: 1,
      purchase_time_millis: 1_735_689_600_000
    )

    not_found = Google::Apis::ClientError.new("Not Found", status_code: 404)

    fake_service = Object.new
    fake_service.define_singleton_method(:get_purchase_subscription) { |*_| raise not_found }
    fake_service.define_singleton_method(:get_purchase_product) { |*_| verified_ot }
    fake_service.define_singleton_method(:acknowledge_purchase_product) { |*_| nil }
    fake_service.define_singleton_method(:get_inappproduct) { |*_| nil }

    GooglePurchaseValidator.stub(:build_google_service, fake_service) do
      assert GooglePurchaseValidator.validate(event, @instance)
    end

    event.reload
    assert event.webhook_validated?
    assert_equal Grovs::Purchases::TYPE_ONE_TIME, event.purchase_type
  end

  test "validate with nil purchase_type succeeds on subscription without fallback" do
    event = create_event(
      transaction_id: "txn_goog_unknown_sub",
      purchase_type: nil
    )

    verified = OpenStruct.new(
      purchase_type: 1,
      price_amount_micros: 5_990_000,
      price_currency_code: "USD",
      start_time_millis: 1_735_689_600_000,
      expiry_time_millis: nil,
      order_id: "GPA.unknown-sub"
    )

    fake_service = Minitest::Mock.new
    fake_service.expect(:get_purchase_subscription, verified, [event.identifier, event.product_id, event.transaction_id])

    GooglePurchaseValidator.stub(:build_google_service, fake_service) do
      assert GooglePurchaseValidator.validate(event, @instance)
    end

    event.reload
    assert_equal Grovs::Purchases::TYPE_SUBSCRIPTION, event.purchase_type
    assert_equal 599, event.price_cents
    fake_service.verify
  end

  # --- validate: project correction ---

  test "validate corrects project to test when purchase_type is 0" do
    event = create_event(transaction_id: "txn_goog_test_proj")

    verified = OpenStruct.new(
      purchase_type: 0, # test purchase
      price_amount_micros: 0,
      price_currency_code: "USD",
      start_time_millis: 1_735_689_600_000,
      expiry_time_millis: nil,
      order_id: "GPA.test-proj"
    )

    fake_service = Minitest::Mock.new
    fake_service.expect(:get_purchase_subscription, verified, [event.identifier, event.product_id, event.transaction_id])

    GooglePurchaseValidator.stub(:build_google_service, fake_service) do
      GooglePurchaseValidator.validate(event, @instance)
    end

    event.reload
    assert_equal @test_project.id, event.project_id
    fake_service.verify
  end

  test "validate keeps production project when purchase_type is 1" do
    event = create_event(transaction_id: "txn_goog_prod_proj")

    verified = OpenStruct.new(
      purchase_type: 1, # production
      price_amount_micros: 0,
      price_currency_code: "USD",
      start_time_millis: 1_735_689_600_000,
      expiry_time_millis: nil,
      order_id: "GPA.prod-proj"
    )

    fake_service = Minitest::Mock.new
    fake_service.expect(:get_purchase_subscription, verified, [event.identifier, event.product_id, event.transaction_id])

    GooglePurchaseValidator.stub(:build_google_service, fake_service) do
      GooglePurchaseValidator.validate(event, @instance)
    end

    event.reload
    assert_equal @project.id, event.project_id
    fake_service.verify
  end

  # --- acknowledge failure is non-fatal ---

  test "validate succeeds even when acknowledge fails" do
    event = create_event(
      transaction_id: "txn_goog_ack_fail",
      purchase_type: Grovs::Purchases::TYPE_ONE_TIME
    )

    verified = OpenStruct.new(
      purchase_type: 1,
      purchase_time_millis: 1_735_689_600_000
    )

    fake_service = Object.new
    fake_service.define_singleton_method(:get_purchase_product) { |*_| verified }
    fake_service.define_singleton_method(:acknowledge_purchase_product) { |*_| raise Google::Apis::ServerError, "server error" }
    fake_service.define_singleton_method(:get_inappproduct) { |*_| nil }

    GooglePurchaseValidator.stub(:build_google_service, fake_service) do
      assert GooglePurchaseValidator.validate(event, @instance)
    end

    event.reload
    assert event.webhook_validated?
  end

  private

  def create_event(transaction_id:, price_cents: 0, purchase_type: Grovs::Purchases::TYPE_SUBSCRIPTION)
    PurchaseEvent.create!(
      event_type: Grovs::Purchases::EVENT_BUY,
      project: @project,
      identifier: "com.test.app",
      price_cents: price_cents,
      currency: "USD",
      date: Time.current,
      transaction_id: transaction_id,
      product_id: "com.test.premium",
      webhook_validated: false,
      store: false,
      purchase_type: purchase_type
    )
  end
end
