require "test_helper"

class GoogleIapIntegrationTest < ActiveSupport::TestCase
  fixtures :instances, :projects, :devices, :purchase_events, :subscription_states

  setup do
    @instance = instances(:one)
    @project = projects(:one)
    @job = ProcessGoogleNotificationJob.new
  end

  # ---------------------------------------------------------------------------
  # Voided subscription RTDN → RefundHandler → REFUND event
  # ---------------------------------------------------------------------------

  test "voided subscription notification creates REFUND event end-to-end" do
    # Create a subscription BUY event
    buy = PurchaseEvent.create!(
      project: @project,
      event_type: Grovs::Purchases::EVENT_BUY,
      transaction_id: "token_int_sub_refund",
      original_transaction_id: "token_int_sub_refund",
      product_id: "com.test.premium",
      identifier: "com.test.app",
      price_cents: 999, currency: "USD", usd_price_cents: 999,
      date: Time.current,
      purchase_type: Grovs::Purchases::TYPE_SUBSCRIPTION,
      order_id: "GPA.int-sub-001",
      webhook_validated: true, store: true,
      store_source: Grovs::Webhooks::GOOGLE
    )

    webhook = IapWebhookMessage.create!(
      payload: "test", notification_type: "",
      source: Grovs::Webhooks::GOOGLE, instance: @instance
    )

    parsed_data = {
      "packageName" => "com.test.app",
      "voidedPurchaseNotification" => {
        "purchaseToken" => "token_int_sub_refund",
        "orderId" => "GPA.int-sub-001",
        "productType" => 1,
        "refundType" => 1
      }
    }

    # Stub only the Google Play API service builder
    fake_service = Object.new
    IapUtils.stub(:build_google_service, ->(_) { fake_service }) do
      @job.perform(webhook.id, parsed_data, @instance.id)
    end

    refund = PurchaseEvent.find_by(
      transaction_id: "token_int_sub_refund_refund",
      event_type: Grovs::Purchases::EVENT_REFUND
    )
    assert refund, "REFUND event should be created"
    assert_equal @project.id, refund.project_id
    assert_equal 999, refund.price_cents
    assert_equal Grovs::Purchases::TYPE_SUBSCRIPTION, refund.purchase_type
  end

  # ---------------------------------------------------------------------------
  # Voided one-time RTDN → RefundHandler → REFUND event
  # ---------------------------------------------------------------------------

  test "voided one-time notification creates REFUND event end-to-end" do
    buy = PurchaseEvent.create!(
      project: @project,
      event_type: Grovs::Purchases::EVENT_BUY,
      transaction_id: "token_int_ot_refund",
      original_transaction_id: "token_int_ot_refund",
      product_id: "com.test.gems",
      identifier: "com.test.app",
      price_cents: 499, currency: "USD", usd_price_cents: 499,
      date: Time.current,
      purchase_type: Grovs::Purchases::TYPE_ONE_TIME,
      order_id: "GPA.int-ot-001",
      webhook_validated: true, store: true,
      store_source: Grovs::Webhooks::GOOGLE
    )

    webhook = IapWebhookMessage.create!(
      payload: "test", notification_type: "",
      source: Grovs::Webhooks::GOOGLE, instance: @instance
    )

    parsed_data = {
      "packageName" => "com.test.app",
      "voidedPurchaseNotification" => {
        "purchaseToken" => "token_int_ot_refund",
        "orderId" => "GPA.int-ot-001",
        "productType" => 2,
        "refundType" => 1
      }
    }

    fake_service = Object.new
    IapUtils.stub(:build_google_service, ->(_) { fake_service }) do
      @job.perform(webhook.id, parsed_data, @instance.id)
    end

    refund = PurchaseEvent.find_by(
      transaction_id: "token_int_ot_refund_refund",
      event_type: Grovs::Purchases::EVENT_REFUND
    )
    assert refund, "REFUND event should be created"
    assert_equal Grovs::Purchases::TYPE_ONE_TIME, refund.purchase_type
  end

  # ---------------------------------------------------------------------------
  # Subscription purchase RTDN → SubscriptionHandler → BUY event (sanity check)
  # ---------------------------------------------------------------------------

  test "subscription purchased notification creates BUY event end-to-end" do
    verified = OpenStruct.new(
      purchase_type: 1,
      price_amount_micros: 9_990_000,
      price_currency_code: "USD",
      start_time_millis: 1_735_689_600_000,
      expiry_time_millis: 1_738_368_000_000,
      order_id: "GPA.int-sub-buy-001"
    )

    fake_service = Object.new
    fake_service.define_singleton_method(:get_purchase_subscription) { |*_| verified }

    webhook = IapWebhookMessage.create!(
      payload: "test", notification_type: "",
      source: Grovs::Webhooks::GOOGLE, instance: @instance
    )

    parsed_data = {
      "packageName" => "com.test.app",
      "subscriptionNotification" => {
        "purchaseToken" => "token_int_sub_buy",
        "subscriptionId" => "sub_premium",
        "notificationType" => 4
      }
    }

    IapUtils.stub(:build_google_service, ->(_) { fake_service }) do
      @job.perform(webhook.id, parsed_data, @instance.id)
    end

    event = PurchaseEvent.find_by(transaction_id: "token_int_sub_buy")
    assert event, "BUY event should be created"
    assert_equal Grovs::Purchases::EVENT_BUY, event.event_type
    assert_equal 999, event.price_cents
    assert_equal Grovs::Purchases::TYPE_SUBSCRIPTION, event.purchase_type
  end

  # ---------------------------------------------------------------------------
  # Bundle purchase via oneTimeProductNotification (no sku) → productsv2 → N BUY events
  # ---------------------------------------------------------------------------

  test "bundle purchase notification creates BUY events for each line item end-to-end" do
    # ProductLineItem objects — no price fields (price comes from catalog)
    line_item_a = OpenStruct.new(product_id: "com.test.sword", product_offer_details: nil)
    line_item_b = OpenStruct.new(product_id: "com.test.shield", product_offer_details: nil)

    # ProductPurchaseV2 uses product_line_item (not line_items) and test_purchase_context (not test_purchase)
    purchase_v2 = OpenStruct.new(
      product_line_item: [line_item_a, line_item_b],
      order_id: "GPA.int-bundle-buy-001",
      test_purchase_context: nil  # nil = production
    )

    # Product catalog for price lookup (batch API returns array with sku)
    batch_products = [
      OpenStruct.new(sku: "com.test.sword", default_price: OpenStruct.new(price_micros: 2_990_000, currency: "USD")),
      OpenStruct.new(sku: "com.test.shield", default_price: OpenStruct.new(price_micros: 4_990_000, currency: "EUR"))
    ]

    fake_service = Object.new
    fake_service.define_singleton_method(:getproductpurchasev2_purchase_productsv2) { |*_| purchase_v2 }
    fake_service.define_singleton_method(:batch_inappproduct_get) { |_pkg, **_kw| OpenStruct.new(inappproduct: batch_products) }

    webhook = IapWebhookMessage.create!(
      payload: "test", notification_type: "",
      source: Grovs::Webhooks::GOOGLE, instance: @instance
    )

    parsed_data = {
      "packageName" => "com.test.app",
      "oneTimeProductNotification" => {
        "purchaseToken" => "token_int_bundle_buy"
        # no "sku" — triggers bundle/v2 path
      }
    }

    IapUtils.stub(:build_google_service, ->(_) { fake_service }) do
      result = @job.perform(webhook.id, parsed_data, @instance.id)
      assert result, "Should return truthy on success"
    end

    events = PurchaseEvent.where(
      original_transaction_id: "token_int_bundle_buy",
      event_type: Grovs::Purchases::EVENT_BUY
    )
    assert_equal 2, events.count, "Should create 2 BUY events for 2-item bundle"

    sword = events.find_by(product_id: "com.test.sword")
    shield = events.find_by(product_id: "com.test.shield")

    assert sword
    assert_equal "token_int_bundle_buy:com.test.sword", sword.transaction_id
    assert_equal 299, sword.price_cents
    assert_equal "USD", sword.currency
    assert_equal "GPA.int-bundle-buy-001", sword.order_id

    assert shield
    assert_equal "token_int_bundle_buy:com.test.shield", shield.transaction_id
    assert_equal 499, shield.price_cents
    assert_equal "EUR", shield.currency
  end

  # ---------------------------------------------------------------------------
  # Bundle purchase then refund → N BUY events → N REFUND events
  # ---------------------------------------------------------------------------

  test "bundle purchase then refund creates matching refund events end-to-end" do
    # Simulate 2 BUY events from a previous bundle purchase
    PurchaseEvent.create!(
      project: @project,
      event_type: Grovs::Purchases::EVENT_BUY,
      transaction_id: "token_int_bundle:product_a",
      original_transaction_id: "token_int_bundle",
      product_id: "com.test.product_a",
      identifier: "com.test.app",
      price_cents: 299, currency: "USD", usd_price_cents: 299,
      date: Time.current,
      purchase_type: Grovs::Purchases::TYPE_ONE_TIME,
      order_id: "GPA.int-bundle-001",
      webhook_validated: true, store: true,
      store_source: Grovs::Webhooks::GOOGLE
    )
    PurchaseEvent.create!(
      project: @project,
      event_type: Grovs::Purchases::EVENT_BUY,
      transaction_id: "token_int_bundle:product_b",
      original_transaction_id: "token_int_bundle",
      product_id: "com.test.product_b",
      identifier: "com.test.app",
      price_cents: 499, currency: "USD", usd_price_cents: 499,
      date: Time.current,
      purchase_type: Grovs::Purchases::TYPE_ONE_TIME,
      order_id: "GPA.int-bundle-001",
      webhook_validated: true, store: true,
      store_source: Grovs::Webhooks::GOOGLE
    )

    webhook = IapWebhookMessage.create!(
      payload: "test", notification_type: "",
      source: Grovs::Webhooks::GOOGLE, instance: @instance
    )

    parsed_data = {
      "packageName" => "com.test.app",
      "voidedPurchaseNotification" => {
        "purchaseToken" => "token_int_bundle",
        "orderId" => "GPA.int-bundle-001",
        "productType" => 2,
        "refundType" => 1
      }
    }

    fake_service = Object.new
    IapUtils.stub(:build_google_service, ->(_) { fake_service }) do
      @job.perform(webhook.id, parsed_data, @instance.id)
    end

    refunds = PurchaseEvent.where(
      event_type: Grovs::Purchases::EVENT_REFUND,
      order_id: "GPA.int-bundle-001"
    )
    assert_equal 2, refunds.count, "Should create 2 REFUND events for 2-item bundle"

    refund_a = refunds.find_by(product_id: "com.test.product_a")
    refund_b = refunds.find_by(product_id: "com.test.product_b")
    assert_equal 299, refund_a.price_cents
    assert_equal 499, refund_b.price_cents
  end
end
