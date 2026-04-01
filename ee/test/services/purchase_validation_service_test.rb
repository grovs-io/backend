require "test_helper"

class PurchaseValidationServiceTest < ActiveSupport::TestCase
  fixtures :instances, :projects, :devices, :visitors, :purchase_events

  test "returns true for already webhook_validated event" do
    event = purchase_events(:buy_event)
    assert event.webhook_validated?

    result = PurchaseValidationService.validate(event, Grovs::Platforms::IOS)
    assert result
  end

  test "returns false for nil event" do
    result = PurchaseValidationService.validate(nil, Grovs::Platforms::IOS)
    assert_not result
  end

  test "returns false for unknown platform" do
    event = PurchaseEvent.create!(
      event_type: Grovs::Purchases::EVENT_BUY,
      project: projects(:one),
      identifier: "com.test.app",
      price_cents: 999,
      currency: "USD",
      date: Time.current,
      transaction_id: "txn_unknown_plat",
      product_id: "com.test.premium",
      webhook_validated: false,
      store: true,
      purchase_type: Grovs::Purchases::TYPE_SUBSCRIPTION
    )

    result = PurchaseValidationService.validate(event, "unknown")
    assert_not result
  end

  # ---------------------------------------------------------------------------
  # Defensive parsing
  # ---------------------------------------------------------------------------

  test "validate_apple returns false when API response missing signedTransactionInfo" do
    event = PurchaseEvent.create!(
      event_type: Grovs::Purchases::EVENT_BUY,
      project: projects(:one),
      identifier: "com.test.app",
      price_cents: 999,
      currency: "USD",
      date: Time.current,
      transaction_id: "txn_apple_no_signed",
      product_id: "com.test.premium",
      webhook_validated: false,
      store: true,
      purchase_type: Grovs::Purchases::TYPE_SUBSCRIPTION
    )

    fake_client = Minitest::Mock.new
    fake_client.expect(:get_transaction_info, { "foo" => "bar" }, [event.transaction_id])

    # Stub decode_jws! to raise if called — proves our guard prevented the call
    bomb = ->(_jws) { raise "decode_jws! should not be called when signedTransactionInfo is missing" }

    ApplePurchaseValidator.stub(:build_apple_client, fake_client) do
      AppStoreServerApi::Utils::Decoder.stub(:decode_jws!, bomb) do
        result = PurchaseValidationService.validate(event, Grovs::Platforms::IOS)
        assert_not result
      end
    end

    # Confirm event was NOT touched
    event.reload
    assert_not event.webhook_validated?

    fake_client.verify
  end

  test "validate_google returns false when Google API returns nil" do
    event = PurchaseEvent.create!(
      event_type: Grovs::Purchases::EVENT_BUY,
      project: projects(:one),
      identifier: "com.test.app",
      price_cents: 999,
      currency: "USD",
      date: Time.current,
      transaction_id: "txn_google_nil",
      product_id: "com.test.premium",
      webhook_validated: false,
      store: true,
      purchase_type: Grovs::Purchases::TYPE_SUBSCRIPTION
    )

    fake_service = Minitest::Mock.new
    fake_service.expect(:get_purchase_subscription, nil, [event.identifier, event.product_id, event.transaction_id])

    # Stub update method to blow up if called — proves guard prevented it
    bomb = ->(*_) { raise "update_from_google_subscription should not be called when API returns nil" }

    GooglePurchaseValidator.stub(:build_google_service, fake_service) do
      GooglePurchaseValidator.stub(:update_from_google_subscription, bomb) do
        result = PurchaseValidationService.validate(event, Grovs::Platforms::ANDROID)
        assert_not result
      end
    end

    fake_service.verify
  end

  # ---------------------------------------------------------------------------
  # Purchase type helpers
  # ---------------------------------------------------------------------------

  test "apple_purchase_type handles Auto-Renewable Subscription" do
    result = IapUtils.apple_purchase_type("Auto-Renewable Subscription")
    assert_equal Grovs::Purchases::TYPE_SUBSCRIPTION, result
  end

  test "apple_purchase_type handles Non-Renewing Subscription" do
    result = IapUtils.apple_purchase_type("Non-Renewing Subscription")
    assert_equal Grovs::Purchases::TYPE_SUBSCRIPTION, result
  end

  test "apple_purchase_type handles Consumable" do
    result = IapUtils.apple_purchase_type("Consumable")
    assert_equal Grovs::Purchases::TYPE_ONE_TIME, result
  end

  test "apple_purchase_type handles nil safely" do
    result = IapUtils.apple_purchase_type(nil)
    assert_equal Grovs::Purchases::TYPE_ONE_TIME, result
  end

  # ---------------------------------------------------------------------------
  # Apple price conversion
  # ---------------------------------------------------------------------------

  test "convert_apple_price converts milliunits to cents" do
    result = IapUtils.convert_apple_price_to_cents(1299)
    assert_equal 129, result
  end

  test "convert_apple_price returns nil for nil input" do
    result = IapUtils.convert_apple_price_to_cents(nil)
    assert_nil result
  end

  test "convert_apple_price returns 0 for zero input" do
    result = IapUtils.convert_apple_price_to_cents(0)
    assert_equal 0, result
  end

  # ---------------------------------------------------------------------------
  # Full Apple validation flow
  # ---------------------------------------------------------------------------

  test "full Apple subscription validation updates event correctly" do
    event = PurchaseEvent.create!(
      event_type: Grovs::Purchases::EVENT_BUY,
      project: projects(:one),
      identifier: "com.test.app",
      price_cents: 0,
      currency: "USD",
      date: Time.current,
      transaction_id: "txn_apple_full_sub",
      product_id: "com.test.premium",
      webhook_validated: false,
      store: false,
      purchase_type: Grovs::Purchases::TYPE_SUBSCRIPTION
    )

    apple_transaction = {
      "price" => 9990,
      "currency" => "EUR",
      "purchaseDate" => 1_735_689_600_000,
      "type" => "Auto-Renewable Subscription",
      "bundleId" => "com.real.app",
      "originalTransactionId" => "apple_orig_001",
      "productId" => "com.real.premium"
    }

    fake_client = Minitest::Mock.new
    fake_client.expect(:get_transaction_info, { "signedTransactionInfo" => "signed_jwt" }, [event.transaction_id])

    ApplePurchaseValidator.stub(:build_apple_client, fake_client) do
      AppStoreServerApi::Utils::Decoder.stub(:decode_jws!, apple_transaction) do
        result = PurchaseValidationService.validate(event, Grovs::Platforms::IOS)
        assert result
      end
    end

    event.reload
    assert event.webhook_validated?
    assert event.store?
    assert_equal 999, event.price_cents  # 9990 / 10
    assert_equal "EUR", event.currency
    assert_equal "com.real.app", event.identifier
    assert_equal "apple_orig_001", event.original_transaction_id
    assert_equal "com.real.premium", event.product_id
    assert_equal Grovs::Purchases::TYPE_SUBSCRIPTION, event.purchase_type
    fake_client.verify
  end

  test "full Apple one-time validation sets TYPE_ONE_TIME" do
    event = PurchaseEvent.create!(
      event_type: Grovs::Purchases::EVENT_BUY,
      project: projects(:one),
      identifier: "com.test.app",
      price_cents: 0,
      currency: "USD",
      date: Time.current,
      transaction_id: "txn_apple_full_ot",
      product_id: "com.test.gems",
      webhook_validated: false,
      store: false,
      purchase_type: Grovs::Purchases::TYPE_ONE_TIME
    )

    apple_transaction = {
      "price" => 4990,
      "currency" => "USD",
      "purchaseDate" => 1_735_689_600_000,
      "type" => "Non-Consumable",
      "bundleId" => "com.real.app",
      "originalTransactionId" => "apple_orig_ot_001",
      "productId" => "com.real.gems"
    }

    fake_client = Minitest::Mock.new
    fake_client.expect(:get_transaction_info, { "signedTransactionInfo" => "signed_jwt" }, [event.transaction_id])

    ApplePurchaseValidator.stub(:build_apple_client, fake_client) do
      AppStoreServerApi::Utils::Decoder.stub(:decode_jws!, apple_transaction) do
        result = PurchaseValidationService.validate(event, Grovs::Platforms::IOS)
        assert result
      end
    end

    event.reload
    assert event.webhook_validated?
    assert_equal 499, event.price_cents
    assert_equal Grovs::Purchases::TYPE_ONE_TIME, event.purchase_type
    fake_client.verify
  end

  # ---------------------------------------------------------------------------
  # Full Google subscription validation flow
  # ---------------------------------------------------------------------------

  test "full Google subscription validation updates event with price and expiry" do
    event = PurchaseEvent.create!(
      event_type: Grovs::Purchases::EVENT_BUY,
      project: projects(:one),
      identifier: "com.test.app",
      price_cents: 0,
      currency: "USD",
      date: Time.current,
      transaction_id: "txn_google_full_sub",
      product_id: "com.test.premium",
      webhook_validated: false,
      store: false,
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
      result = PurchaseValidationService.validate(event, Grovs::Platforms::ANDROID)
      assert result
    end

    event.reload
    assert event.webhook_validated?
    assert event.store?
    assert_equal 1299, event.price_cents
    assert_equal "EUR", event.currency
    assert_equal "GPA.3345-3232", event.original_transaction_id
    assert_equal Time.at(1_738_368_000), event.expires_date
    assert_equal Grovs::Purchases::TYPE_SUBSCRIPTION, event.purchase_type
    fake_service.verify
  end

  test "full Google one-time validation updates event with product details price" do
    event = PurchaseEvent.create!(
      event_type: Grovs::Purchases::EVENT_BUY,
      project: projects(:one),
      identifier: "com.test.app",
      price_cents: 0,
      currency: "USD",
      date: Time.current,
      transaction_id: "txn_google_full_ot",
      product_id: "com.test.gems",
      webhook_validated: false,
      store: false,
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
      result = PurchaseValidationService.validate(event, Grovs::Platforms::ANDROID)
      assert result
    end

    event.reload
    assert event.webhook_validated?
    assert_equal 499, event.price_cents
    assert_equal "GBP", event.currency
    assert_equal Grovs::Purchases::TYPE_ONE_TIME, event.purchase_type
    fake_service.verify
  end

  test "Google unknown purchase_type falls back from subscription 404 to one-time" do
    event = PurchaseEvent.create!(
      event_type: Grovs::Purchases::EVENT_BUY,
      project: projects(:one),
      identifier: "com.test.app",
      price_cents: 0,
      currency: "USD",
      date: Time.current,
      transaction_id: "txn_google_fallback",
      product_id: "com.test.gems",
      webhook_validated: false,
      store: false,
      purchase_type: nil # unknown
    )

    verified_ot = OpenStruct.new(
      purchase_type: 1,
      purchase_time_millis: 1_735_689_600_000
    )

    not_found_error = Google::Apis::ClientError.new("Not Found", status_code: 404)

    fake_service = Object.new
    fake_service.define_singleton_method(:get_purchase_subscription) { |*_| raise not_found_error }
    fake_service.define_singleton_method(:get_purchase_product) { |*_| verified_ot }
    fake_service.define_singleton_method(:acknowledge_purchase_product) { |*_| nil }
    fake_service.define_singleton_method(:get_inappproduct) { |*_| nil }

    GooglePurchaseValidator.stub(:build_google_service, fake_service) do
      result = PurchaseValidationService.validate(event, Grovs::Platforms::ANDROID)
      assert result
    end

    event.reload
    assert event.webhook_validated?
    assert_equal Grovs::Purchases::TYPE_ONE_TIME, event.purchase_type
  end

  test "Google order_id regex strips .N suffix" do
    event = PurchaseEvent.create!(
      event_type: Grovs::Purchases::EVENT_BUY,
      project: projects(:one),
      identifier: "com.test.app",
      price_cents: 0,
      currency: "USD",
      date: Time.current,
      transaction_id: "txn_google_order_strip",
      product_id: "com.test.premium",
      webhook_validated: false,
      store: false,
      purchase_type: Grovs::Purchases::TYPE_SUBSCRIPTION
    )

    verified = OpenStruct.new(
      purchase_type: 1,
      price_amount_micros: 0,
      price_currency_code: "USD",
      start_time_millis: 1_735_689_600_000,
      expiry_time_millis: nil,
      order_id: "GPA.3345-3232.5"
    )

    fake_service = Minitest::Mock.new
    fake_service.expect(:get_purchase_subscription, verified, [event.identifier, event.product_id, event.transaction_id])

    GooglePurchaseValidator.stub(:build_google_service, fake_service) do
      PurchaseValidationService.validate(event, Grovs::Platforms::ANDROID)
    end

    event.reload
    assert_equal "GPA.3345-3232", event.original_transaction_id
    fake_service.verify
  end

  test "Google nil order_id falls back to event transaction_id" do
    event = PurchaseEvent.create!(
      event_type: Grovs::Purchases::EVENT_BUY,
      project: projects(:one),
      identifier: "com.test.app",
      price_cents: 0,
      currency: "USD",
      date: Time.current,
      transaction_id: "txn_google_nil_order",
      product_id: "com.test.premium",
      webhook_validated: false,
      store: false,
      purchase_type: Grovs::Purchases::TYPE_SUBSCRIPTION
    )

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
      PurchaseValidationService.validate(event, Grovs::Platforms::ANDROID)
    end

    event.reload
    assert_equal "txn_google_nil_order", event.original_transaction_id
    fake_service.verify
  end

  test "Google purchase_type 0 corrects to test project" do
    prod_project = projects(:one)       # test: false (default)
    test_project = projects(:one_test)  # test: true

    event = PurchaseEvent.create!(
      event_type: Grovs::Purchases::EVENT_BUY,
      project: prod_project,
      identifier: "com.test.app",
      price_cents: 0,
      currency: "USD",
      date: Time.current,
      transaction_id: "txn_google_proj_correct",
      product_id: "com.test.premium",
      webhook_validated: false,
      store: false,
      purchase_type: Grovs::Purchases::TYPE_SUBSCRIPTION
    )

    verified = OpenStruct.new(
      purchase_type: 0, # test
      price_amount_micros: 0,
      price_currency_code: "USD",
      start_time_millis: 1_735_689_600_000,
      expiry_time_millis: nil,
      order_id: "GPA.proj-correct"
    )

    fake_service = Minitest::Mock.new
    fake_service.expect(:get_purchase_subscription, verified, [event.identifier, event.product_id, event.transaction_id])

    GooglePurchaseValidator.stub(:build_google_service, fake_service) do
      PurchaseValidationService.validate(event, Grovs::Platforms::ANDROID)
    end

    event.reload
    assert_equal test_project.id, event.project_id
    fake_service.verify
  end

  test "subscriptions get expires_date but one-time does not" do
    # Subscription with expires_date
    sub_event = PurchaseEvent.create!(
      event_type: Grovs::Purchases::EVENT_BUY,
      project: projects(:one),
      identifier: "com.test.app",
      price_cents: 0,
      currency: "USD",
      date: Time.current,
      transaction_id: "txn_google_expiry_sub",
      product_id: "com.test.premium",
      webhook_validated: false,
      store: false,
      purchase_type: Grovs::Purchases::TYPE_SUBSCRIPTION
    )

    verified_sub = OpenStruct.new(
      purchase_type: 1,
      price_amount_micros: 0,
      price_currency_code: "USD",
      start_time_millis: 1_735_689_600_000,
      expiry_time_millis: 1_738_368_000_000,
      order_id: "GPA.expiry-sub"
    )

    fake_service = Minitest::Mock.new
    fake_service.expect(:get_purchase_subscription, verified_sub, [sub_event.identifier, sub_event.product_id, sub_event.transaction_id])

    GooglePurchaseValidator.stub(:build_google_service, fake_service) do
      PurchaseValidationService.validate(sub_event, Grovs::Platforms::ANDROID)
    end

    sub_event.reload
    assert_equal Time.at(1_738_368_000), sub_event.expires_date
    fake_service.verify

    # One-time without expires_date
    ot_event = PurchaseEvent.create!(
      event_type: Grovs::Purchases::EVENT_BUY,
      project: projects(:one),
      identifier: "com.test.app",
      price_cents: 0,
      currency: "USD",
      date: Time.current,
      transaction_id: "txn_google_expiry_ot",
      product_id: "com.test.gems",
      webhook_validated: false,
      store: false,
      purchase_type: Grovs::Purchases::TYPE_ONE_TIME
    )

    verified_ot = OpenStruct.new(
      purchase_type: 1,
      purchase_time_millis: 1_735_689_600_000
    )

    fake_service2 = Minitest::Mock.new
    fake_service2.expect(:get_purchase_product, verified_ot, [ot_event.identifier, ot_event.product_id, ot_event.transaction_id])
    fake_service2.expect(:acknowledge_purchase_product, nil, [ot_event.identifier, ot_event.product_id, ot_event.transaction_id])
    fake_service2.expect(:get_inappproduct, nil, [ot_event.identifier, ot_event.product_id])

    GooglePurchaseValidator.stub(:build_google_service, fake_service2) do
      PurchaseValidationService.validate(ot_event, Grovs::Platforms::ANDROID)
    end

    ot_event.reload
    assert_nil ot_event.expires_date
    fake_service2.verify
  end
end
