require "test_helper"

class ApplePurchaseValidatorTest < ActiveSupport::TestCase
  fixtures :instances, :projects, :devices, :visitors, :purchase_events

  setup do
    @instance = instances(:one)
    @project = projects(:one)
  end

  # --- validate: guard clauses ---

  test "validate returns false when build_apple_client returns nil" do
    event = create_event(transaction_id: "txn_no_client")

    ApplePurchaseValidator.stub(:build_apple_client, nil) do
      assert_not ApplePurchaseValidator.validate(event, @instance)
    end

    event.reload
    assert_not event.webhook_validated?
  end

  test "validate returns false when API response missing signedTransactionInfo" do
    event = create_event(transaction_id: "txn_no_signed_info")

    fake_client = Minitest::Mock.new
    fake_client.expect(:get_transaction_info, { "foo" => "bar" }, [event.transaction_id])

    ApplePurchaseValidator.stub(:build_apple_client, fake_client) do
      assert_not ApplePurchaseValidator.validate(event, @instance)
    end

    event.reload
    assert_not event.webhook_validated?
    fake_client.verify
  end

  test "validate returns false when decode_jws! returns nil" do
    event = create_event(transaction_id: "txn_decode_nil")

    fake_client = Minitest::Mock.new
    fake_client.expect(:get_transaction_info, { "signedTransactionInfo" => "jwt" }, [event.transaction_id])

    ApplePurchaseValidator.stub(:build_apple_client, fake_client) do
      AppStoreServerApi::Utils::Decoder.stub(:decode_jws!, nil) do
        assert_not ApplePurchaseValidator.validate(event, @instance)
      end
    end

    event.reload
    assert_not event.webhook_validated?
    fake_client.verify
  end

  # --- validate: error handling ---

  test "validate returns false on JWT::DecodeError" do
    event = create_event(transaction_id: "txn_jwt_err")

    fake_client = Minitest::Mock.new
    fake_client.expect(:get_transaction_info, nil) { raise JWT::DecodeError, "bad token" }

    ApplePurchaseValidator.stub(:build_apple_client, fake_client) do
      assert_not ApplePurchaseValidator.validate(event, @instance)
    end
  end

  test "validate returns false on JSON::ParserError" do
    event = create_event(transaction_id: "txn_json_err")

    fake_client = Minitest::Mock.new
    fake_client.expect(:get_transaction_info, nil) { raise JSON::ParserError, "malformed" }

    ApplePurchaseValidator.stub(:build_apple_client, fake_client) do
      assert_not ApplePurchaseValidator.validate(event, @instance)
    end
  end

  # --- validate: subscription flow ---

  test "validate updates subscription event with correct fields" do
    event = create_event(
      transaction_id: "txn_apple_sub",
      price_cents: 0,
      purchase_type: Grovs::Purchases::TYPE_SUBSCRIPTION
    )

    transaction = {
      "price" => 9990,
      "currency" => "EUR",
      "purchaseDate" => 1_735_689_600_000,
      "type" => "Auto-Renewable Subscription",
      "bundleId" => "com.real.app",
      "originalTransactionId" => "orig_sub_001",
      "productId" => "com.real.premium"
    }

    fake_client = Minitest::Mock.new
    fake_client.expect(:get_transaction_info, { "signedTransactionInfo" => "jwt" }, [event.transaction_id])

    ApplePurchaseValidator.stub(:build_apple_client, fake_client) do
      AppStoreServerApi::Utils::Decoder.stub(:decode_jws!, transaction) do
        assert ApplePurchaseValidator.validate(event, @instance)
      end
    end

    event.reload
    assert event.webhook_validated?
    assert event.store?
    assert_equal 999, event.price_cents
    assert_equal "EUR", event.currency
    assert_equal "com.real.app", event.identifier
    assert_equal "orig_sub_001", event.original_transaction_id
    assert_equal "com.real.premium", event.product_id
    assert_equal Grovs::Purchases::TYPE_SUBSCRIPTION, event.purchase_type
    assert_equal Time.at(1_735_689_600), event.date
    fake_client.verify
  end

  # --- validate: one-time flow ---

  test "validate updates one-time event with TYPE_ONE_TIME" do
    event = create_event(
      transaction_id: "txn_apple_ot",
      price_cents: 0,
      purchase_type: Grovs::Purchases::TYPE_ONE_TIME
    )

    transaction = {
      "price" => 4990,
      "currency" => "USD",
      "purchaseDate" => 1_735_689_600_000,
      "type" => "Non-Consumable",
      "bundleId" => "com.real.app",
      "originalTransactionId" => "orig_ot_001",
      "productId" => "com.real.gems"
    }

    fake_client = Minitest::Mock.new
    fake_client.expect(:get_transaction_info, { "signedTransactionInfo" => "jwt" }, [event.transaction_id])

    ApplePurchaseValidator.stub(:build_apple_client, fake_client) do
      AppStoreServerApi::Utils::Decoder.stub(:decode_jws!, transaction) do
        assert ApplePurchaseValidator.validate(event, @instance)
      end
    end

    event.reload
    assert event.webhook_validated?
    assert_equal 499, event.price_cents
    assert_equal Grovs::Purchases::TYPE_ONE_TIME, event.purchase_type
    fake_client.verify
  end

  # --- validate: price preservation ---

  test "validate preserves existing non-zero price for one-time purchase" do
    event = create_event(
      transaction_id: "txn_apple_keep_price",
      price_cents: 1299,
      currency: "GBP",
      purchase_type: Grovs::Purchases::TYPE_ONE_TIME
    )

    transaction = {
      "price" => 9990,
      "currency" => "USD",
      "purchaseDate" => 1_735_689_600_000,
      "type" => "Non-Consumable",
      "bundleId" => "com.real.app",
      "originalTransactionId" => "orig_keep_price",
      "productId" => "com.real.gems"
    }

    fake_client = Minitest::Mock.new
    fake_client.expect(:get_transaction_info, { "signedTransactionInfo" => "jwt" }, [event.transaction_id])

    ApplePurchaseValidator.stub(:build_apple_client, fake_client) do
      AppStoreServerApi::Utils::Decoder.stub(:decode_jws!, transaction) do
        ApplePurchaseValidator.validate(event, @instance)
      end
    end

    event.reload
    # One-time with existing non-zero price: should keep original price
    assert_equal 1299, event.price_cents
    assert_equal "GBP", event.currency
  end

  test "validate overwrites price for subscription even when non-zero" do
    event = create_event(
      transaction_id: "txn_apple_sub_overwrite",
      price_cents: 500,
      currency: "GBP",
      purchase_type: Grovs::Purchases::TYPE_SUBSCRIPTION
    )

    transaction = {
      "price" => 9990,
      "currency" => "EUR",
      "purchaseDate" => 1_735_689_600_000,
      "type" => "Auto-Renewable Subscription",
      "bundleId" => "com.real.app",
      "originalTransactionId" => "orig_sub_overwrite",
      "productId" => "com.real.premium"
    }

    fake_client = Minitest::Mock.new
    fake_client.expect(:get_transaction_info, { "signedTransactionInfo" => "jwt" }, [event.transaction_id])

    ApplePurchaseValidator.stub(:build_apple_client, fake_client) do
      AppStoreServerApi::Utils::Decoder.stub(:decode_jws!, transaction) do
        ApplePurchaseValidator.validate(event, @instance)
      end
    end

    event.reload
    # Subscriptions always get price updated from Apple
    assert_equal 999, event.price_cents
    assert_equal "EUR", event.currency
  end

  private

  def create_event(transaction_id:, price_cents: 0, currency: "USD", purchase_type: Grovs::Purchases::TYPE_SUBSCRIPTION)
    PurchaseEvent.create!(
      event_type: Grovs::Purchases::EVENT_BUY,
      project: @project,
      identifier: "com.test.app",
      price_cents: price_cents,
      currency: currency,
      date: Time.current,
      transaction_id: transaction_id,
      product_id: "com.test.premium",
      webhook_validated: false,
      store: false,
      purchase_type: purchase_type
    )
  end
end
