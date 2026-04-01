require "test_helper"

class GoogleIapServiceTest < ActiveSupport::TestCase
  fixtures :instances, :projects, :devices, :visitors, :purchase_events, :subscription_states

  setup do
    @project = projects(:one)
    @instance = instances(:one)
    @helper = GoogleIapService.new
  end

  # ---------------------------------------------------------------------------
  # Defensive parsing — missing fields
  # ---------------------------------------------------------------------------

  test "handle_notification returns false when packageName missing" do
    webhook = create_webhook

    notification = {
      "subscriptionNotification" => {
        "purchaseToken" => "token_123",
        "subscriptionId" => "sub_001",
        "notificationType" => 4
      }
    }

    build_called = false
    spy = lambda { |_instance| 
      build_called = true
      nil
    }
    IapUtils.stub(:build_google_service, spy) do
      result = @helper.handle_notification(notification, @instance, webhook)
      assert_equal false, result
    end
    assert_not build_called, "Guard should prevent build_google_service from being called"
  end

  test "handle_notification returns false when purchaseToken missing from subscription notification" do
    webhook = create_webhook
    fake_service = build_fake_service

    notification = {
      "packageName" => "com.test.app",
      "subscriptionNotification" => {
        "subscriptionId" => "sub_001",
        "notificationType" => 4
      }
    }

    IapUtils.stub(:build_google_service, ->(_) { fake_service }) do
      result = @helper.handle_notification(notification, @instance, webhook)
      assert_equal false, result
    end
  end

  test "handle_notification returns false when purchaseToken missing from one-time notification" do
    webhook = create_webhook
    fake_service = build_fake_service

    notification = {
      "packageName" => "com.test.app",
      "oneTimeProductNotification" => {
        "sku" => "product_001"
      }
    }

    IapUtils.stub(:build_google_service, ->(_) { fake_service }) do
      result = @helper.handle_notification(notification, @instance, webhook)
      assert_equal false, result
    end
  end

  # ---------------------------------------------------------------------------
  # Attribution and event creation (via SubscriptionHandler)
  # ---------------------------------------------------------------------------

  test "shared event gateway creates event with attribution from previous purchase" do
    @helper.instance_variable_set(:@service, Object.new)

    event = @helper.send(
      :handle_google_purchase_event,
      event_type: Grovs::Purchases::EVENT_BUY,
      project: @project,
      transaction_id: "google_txn_test",
      product_id: "com.test.premium",
      price_cents: 999,
      currency: "USD",
      date: Time.current,
      purchase_type: Grovs::Purchases::TYPE_SUBSCRIPTION,
      identifier: "com.test.app",
      original_transaction_id: "orig_txn_001"
    )

    assert event
    assert_equal devices(:ios_device).id, event.device_id
  end

  # ---------------------------------------------------------------------------
  # Subscription price conversion and field extraction
  # ---------------------------------------------------------------------------

  test "subscription price_amount_micros converts to cents via /10000" do
    verified = OpenStruct.new(
      purchase_type: 1,
      price_amount_micros: 12_990_000,
      price_currency_code: "USD",
      start_time_millis: 1_735_689_600_000,
      expiry_time_millis: 1_738_368_000_000,
      order_id: "GPA.1234-5678.0"
    )

    webhook = create_webhook
    fake_service = build_fake_service(get_purchase_subscription: verified)

    notification = build_subscription_notification("token_sub_price", "sub_premium", 4)

    IapUtils.stub(:build_google_service, ->(_) { fake_service }) do
      @helper.handle_notification(notification, @instance, webhook)
    end

    event = PurchaseEvent.find_by(transaction_id: "token_sub_price")
    assert event
    assert_equal 1299, event.price_cents
    assert_equal "USD", event.currency
  end

  test "subscription price_amount_micros nil results in price 0" do
    verified = OpenStruct.new(
      purchase_type: 1,
      price_amount_micros: nil,
      price_currency_code: nil,
      start_time_millis: 1_735_689_600_000,
      order_id: "GPA.nil-price"
    )

    webhook = create_webhook
    fake_service = build_fake_service(get_purchase_subscription: verified)

    notification = build_subscription_notification("token_nil_price", "sub_premium", 4)

    IapUtils.stub(:build_google_service, ->(_) { fake_service }) do
      @helper.handle_notification(notification, @instance, webhook)
    end

    event = PurchaseEvent.find_by(transaction_id: "token_nil_price")
    assert event
    assert_equal 0, event.price_cents
    assert_equal "USD", event.currency
  end

  test "subscription start_time_millis parsed as Time" do
    verified = OpenStruct.new(
      purchase_type: 1,
      price_amount_micros: 0,
      price_currency_code: "USD",
      start_time_millis: 1_735_689_600_000,
      order_id: "GPA.ts-test"
    )

    webhook = create_webhook
    fake_service = build_fake_service(get_purchase_subscription: verified)

    notification = build_subscription_notification("token_ts_test", "sub_premium", 4)

    IapUtils.stub(:build_google_service, ->(_) { fake_service }) do
      @helper.handle_notification(notification, @instance, webhook)
    end

    event = PurchaseEvent.find_by(transaction_id: "token_ts_test")
    assert event
    assert_equal Time.at(1_735_689_600), event.date
  end

  test "subscription order_id strips .N suffix for original_transaction_id" do
    verified = OpenStruct.new(
      purchase_type: 1,
      price_amount_micros: 0,
      price_currency_code: "USD",
      start_time_millis: 1_735_689_600_000,
      order_id: "GPA.1234-5678.0"
    )

    webhook = create_webhook
    fake_service = build_fake_service(get_purchase_subscription: verified)

    notification = build_subscription_notification("token_order_dedup", "sub_premium", 4)

    IapUtils.stub(:build_google_service, ->(_) { fake_service }) do
      @helper.handle_notification(notification, @instance, webhook)
    end

    event = PurchaseEvent.find_by(transaction_id: "token_order_dedup")
    assert event
    assert_equal "GPA.1234-5678", event.original_transaction_id
  end

  test "subscription nil order_id falls back to purchase_token" do
    verified = OpenStruct.new(
      purchase_type: 1,
      price_amount_micros: 0,
      price_currency_code: "USD",
      start_time_millis: 1_735_689_600_000,
      order_id: nil
    )

    webhook = create_webhook
    fake_service = build_fake_service(get_purchase_subscription: verified)

    notification = build_subscription_notification("token_nil_order", "sub_premium", 4)

    IapUtils.stub(:build_google_service, ->(_) { fake_service }) do
      @helper.handle_notification(notification, @instance, webhook)
    end

    event = PurchaseEvent.find_by(transaction_id: "token_nil_order")
    assert event
    assert_equal "token_nil_order", event.original_transaction_id
  end

  test "purchase_type 0 selects test project" do
    test_project = projects(:one_test)
    assert test_project.test?, "Fixture project :one_test should be the test project"

    verified = OpenStruct.new(
      purchase_type: 0,
      price_amount_micros: 0,
      price_currency_code: "USD",
      start_time_millis: 1_735_689_600_000,
      order_id: "GPA.test-proj"
    )

    webhook = create_webhook
    fake_service = build_fake_service(get_purchase_subscription: verified)

    notification = build_subscription_notification("token_test_proj", "sub_premium", 4)

    IapUtils.stub(:build_google_service, ->(_) { fake_service }) do
      @helper.handle_notification(notification, @instance, webhook)
    end

    event = PurchaseEvent.find_by(transaction_id: "token_test_proj")
    assert event
    assert_equal test_project.id, event.project_id
  end

  test "purchase_type 1 selects production project" do
    prod_project = projects(:one)

    verified = OpenStruct.new(
      purchase_type: 1,
      price_amount_micros: 0,
      price_currency_code: "USD",
      start_time_millis: 1_735_689_600_000,
      order_id: "GPA.prod-proj"
    )

    webhook = create_webhook
    fake_service = build_fake_service(get_purchase_subscription: verified)

    notification = build_subscription_notification("token_prod_proj", "sub_premium", 4)

    IapUtils.stub(:build_google_service, ->(_) { fake_service }) do
      @helper.handle_notification(notification, @instance, webhook)
    end

    event = PurchaseEvent.find_by(transaction_id: "token_prod_proj")
    assert event
    assert_equal prod_project.id, event.project_id
  end

  # ---------------------------------------------------------------------------
  # One-time product tests
  # ---------------------------------------------------------------------------

  test "one-time purchase price from product_details default_price" do
    verified = OpenStruct.new(
      purchase_type: 1,
      purchase_time_millis: 1_735_689_600_000
    )

    product_details = OpenStruct.new(
      default_price: OpenStruct.new(price_micros: 4_990_000, currency: "EUR")
    )

    webhook = create_webhook

    notification = {
      "packageName" => "com.test.app",
      "oneTimeProductNotification" => {
        "purchaseToken" => "token_ot_price",
        "sku" => "gems_500"
      }
    }

    fake_service = build_fake_service(
      get_purchase_product: verified,
      acknowledge_purchase_product: nil,
      get_inappproduct: product_details
    )

    IapUtils.stub(:build_google_service, ->(_) { fake_service }) do
      @helper.handle_notification(notification, @instance, webhook)
    end

    event = PurchaseEvent.find_by(transaction_id: "token_ot_price")
    assert event
    assert_equal 499, event.price_cents
    assert_equal "EUR", event.currency
  end

  test "one-time purchase nil product_details defaults to price 0 USD" do
    verified = OpenStruct.new(
      purchase_type: 1,
      purchase_time_millis: 1_735_689_600_000
    )

    webhook = create_webhook

    notification = {
      "packageName" => "com.test.app",
      "oneTimeProductNotification" => {
        "purchaseToken" => "token_ot_nil",
        "sku" => "gems_500"
      }
    }

    fake_service = build_fake_service(
      get_purchase_product: verified,
      acknowledge_purchase_product: nil,
      get_inappproduct: nil
    )

    IapUtils.stub(:build_google_service, ->(_) { fake_service }) do
      @helper.handle_notification(notification, @instance, webhook)
    end

    event = PurchaseEvent.find_by(transaction_id: "token_ot_nil")
    assert event
    assert_equal 0, event.price_cents
    assert_equal "USD", event.currency
  end

  test "subscription notification creates TYPE_SUBSCRIPTION and one-time creates TYPE_ONE_TIME" do
    sub_verified = OpenStruct.new(
      purchase_type: 1, price_amount_micros: 0,
      price_currency_code: "USD", start_time_millis: 1_735_689_600_000,
      order_id: "GPA.type-test"
    )

    ot_verified = OpenStruct.new(
      purchase_type: 1,
      purchase_time_millis: 1_735_689_600_000
    )

    # Subscription notification
    sub_webhook = create_webhook
    sub_notification = build_subscription_notification("token_type_sub", "sub_premium", 4)

    sub_service = build_fake_service(get_purchase_subscription: sub_verified)

    IapUtils.stub(:build_google_service, ->(_) { sub_service }) do
      @helper.handle_notification(sub_notification, @instance, sub_webhook)
    end

    sub_event = PurchaseEvent.find_by(transaction_id: "token_type_sub")
    assert_equal Grovs::Purchases::TYPE_SUBSCRIPTION, sub_event.purchase_type

    # One-time notification
    ot_webhook = create_webhook
    ot_notification = {
      "packageName" => "com.test.app",
      "oneTimeProductNotification" => {
        "purchaseToken" => "token_type_ot",
        "sku" => "gems_500"
      }
    }

    ot_service = build_fake_service(
      get_purchase_product: ot_verified,
      acknowledge_purchase_product: nil,
      get_inappproduct: nil
    )

    IapUtils.stub(:build_google_service, ->(_) { ot_service }) do
      @helper.handle_notification(ot_notification, @instance, ot_webhook)
    end

    ot_event = PurchaseEvent.find_by(transaction_id: "token_type_ot")
    assert_equal Grovs::Purchases::TYPE_ONE_TIME, ot_event.purchase_type
  end

  # ---------------------------------------------------------------------------
  # One-time product — monetization API fallback
  # ---------------------------------------------------------------------------

  test "one-time purchase falls back to monetization API when legacy inappproducts fails" do
    verified = OpenStruct.new(
      purchase_type: 1,
      purchase_time_millis: 1_735_689_600_000
    )

    us_price = OpenStruct.new(units: 3, nanos: 490_000_000, currency_code: "USD")
    us_config = OpenStruct.new(region_code: "US", price: us_price)
    option = OpenStruct.new(regional_pricing_and_availability_configs: [us_config])
    monetization_product = OpenStruct.new(purchase_options: [option])

    call_log = []
    fake_service = Object.new
    fake_service.define_singleton_method(:get_purchase_product) { |*_| verified }
    fake_service.define_singleton_method(:acknowledge_purchase_product) { |*_| nil }
    fake_service.define_singleton_method(:get_inappproduct) do |*_|
      call_log << :get_inappproduct
      raise Google::Apis::ClientError.new("must use OneTimeProductsService", status_code: 400)
    end
    fake_service.define_singleton_method(:get_monetization_onetimeproduct) do |*_|
      call_log << :get_monetization_onetimeproduct
      monetization_product
    end

    webhook = create_webhook
    notification = {
      "packageName" => "com.test.app",
      "oneTimeProductNotification" => {
        "purchaseToken" => "token_monetization_fallback",
        "sku" => "gems_500"
      }
    }

    IapUtils.stub(:build_google_service, ->(_) { fake_service }) do
      @helper.handle_notification(notification, @instance, webhook)
    end

    event = PurchaseEvent.find_by(transaction_id: "token_monetization_fallback")
    assert event
    assert_equal 349, event.price_cents
    assert_equal "USD", event.currency
    assert_includes call_log, :get_inappproduct
    assert_includes call_log, :get_monetization_onetimeproduct
  end

  test "one-time purchase gets price 0 when both legacy and monetization APIs fail" do
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
      raise Google::Apis::ClientError.new("not found", status_code: 404)
    end

    webhook = create_webhook
    notification = {
      "packageName" => "com.test.app",
      "oneTimeProductNotification" => {
        "purchaseToken" => "token_both_fail",
        "sku" => "gems_500"
      }
    }

    IapUtils.stub(:build_google_service, ->(_) { fake_service }) do
      @helper.handle_notification(notification, @instance, webhook)
    end

    event = PurchaseEvent.find_by(transaction_id: "token_both_fail")
    assert event
    assert_equal 0, event.price_cents
    assert_equal "USD", event.currency
  end

  # ---------------------------------------------------------------------------
  # 7. Bundle via v2 with monetization fallback on get_product_details
  # ---------------------------------------------------------------------------

  test "bundle via v2 uses monetization fallback for product pricing" do
    line_item_1 = OpenStruct.new(product_id: "gem_100")
    line_item_2 = OpenStruct.new(product_id: "gem_200")
    purchase_v2 = OpenStruct.new(
      product_line_item: [line_item_1, line_item_2],
      order_id: "GPA.bundle-test",
      purchase_time_millis: 1_735_689_600_000
    )

    us_price_1 = OpenStruct.new(units: 1, nanos: 990_000_000, currency_code: "USD")
    us_config_1 = OpenStruct.new(region_code: "US", price: us_price_1)
    monetization_1 = OpenStruct.new(purchase_options: [OpenStruct.new(regional_pricing_and_availability_configs: [us_config_1])])

    us_price_2 = OpenStruct.new(units: 3, nanos: 490_000_000, currency_code: "USD")
    us_config_2 = OpenStruct.new(region_code: "US", price: us_price_2)
    monetization_2 = OpenStruct.new(purchase_options: [OpenStruct.new(regional_pricing_and_availability_configs: [us_config_2])])

    monetization_map = { "gem_100" => monetization_1, "gem_200" => monetization_2 }

    fake_service = Object.new
    fake_service.define_singleton_method(:getproductpurchasev2_purchase_productsv2) { |*_| purchase_v2 }
    fake_service.define_singleton_method(:batch_inappproduct_get) do |*_|
      raise Google::Apis::ClientError.new("batch not supported", status_code: 400)
    end
    fake_service.define_singleton_method(:get_inappproduct) do |*_|
      raise Google::Apis::ClientError.new("must use OneTimeProductsService", status_code: 400)
    end
    fake_service.define_singleton_method(:get_monetization_onetimeproduct) { |_pkg, pid| monetization_map[pid] }

    webhook = create_webhook
    # No sku → triggers bundle/v2 path
    notification = {
      "packageName" => "com.test.app",
      "oneTimeProductNotification" => {
        "purchaseToken" => "token_bundle_monetization",
        "notificationType" => 1
      }
    }

    IapUtils.stub(:build_google_service, ->(_) { fake_service }) do
      @helper.handle_notification(notification, @instance, webhook)
    end

    event_1 = PurchaseEvent.find_by(transaction_id: "token_bundle_monetization:gem_100")
    event_2 = PurchaseEvent.find_by(transaction_id: "token_bundle_monetization:gem_200")
    assert event_1, "Should create event for gem_100"
    assert event_2, "Should create event for gem_200"
    assert_equal 199, event_1.price_cents
    assert_equal 349, event_2.price_cents
  end

  # ---------------------------------------------------------------------------
  # Router — unknown notification type
  # ---------------------------------------------------------------------------

  test "handle_notification returns skipped for unknown notification type" do
    webhook = create_webhook
    fake_service = build_fake_service

    notification = {
      "packageName" => "com.test.app",
      "testNotification" => { "version" => "1.0" }
    }

    IapUtils.stub(:build_google_service, ->(_) { fake_service }) do
      result = @helper.handle_notification(notification, @instance, webhook)
      assert_equal :skipped, result
    end
  end

  private

  def create_webhook
    IapWebhookMessage.create!(
      payload: "test",
      notification_type: "UNKNOWN",
      source: Grovs::Webhooks::GOOGLE,
      instance: @instance
    )
  end

  def build_subscription_notification(token, subscription_id, notification_type)
    {
      "packageName" => "com.test.app",
      "subscriptionNotification" => {
        "purchaseToken" => token,
        "subscriptionId" => subscription_id,
        "notificationType" => notification_type
      }
    }
  end

  # Build a fake Google API service that responds to the methods handlers call.
  # Pass return values for each method; unspecified methods raise NoMethodError (safe).
  def build_fake_service(**responses)
    service = Object.new

    responses.each do |method_name, return_value|
      service.define_singleton_method(method_name) { |*_args| return_value }
    end

    service
  end
end
