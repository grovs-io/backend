require "test_helper"

class GoogleIapService::SubscriptionHandlerTest < ActiveSupport::TestCase
  fixtures :instances, :projects

  setup do
    @project = projects(:one)
    @instance = instances(:one)
    @service_instance = GoogleIapService.new
  end

  # ---------------------------------------------------------------------------
  # map_notification_to_event
  # ---------------------------------------------------------------------------

  test "map_notification_to_event returns BUY for purchase types" do
    [1, 2, 4, 7].each do |type|
      result = @service_instance.send(:map_notification_to_event, type)
      assert_equal Grovs::Purchases::EVENT_BUY, result, "Type #{type} should map to BUY"
    end
  end

  test "map_notification_to_event returns CANCEL for cancel types" do
    [3, 12, 13, 20].each do |type|
      result = @service_instance.send(:map_notification_to_event, type)
      assert_equal Grovs::Purchases::EVENT_CANCEL, result, "Type #{type} should map to CANCEL"
    end
  end

  test "map_notification_to_event returns nil for non-purchase types" do
    [5, 6, 8, 9, 10, 11, 19].each do |type|
      result = @service_instance.send(:map_notification_to_event, type)
      assert_nil result, "Type #{type} should map to nil"
    end
  end

  # ---------------------------------------------------------------------------
  # handle_subscription_notification — skipped for no-op types
  # ---------------------------------------------------------------------------

  test "returns skipped for no-op notification types" do
    verified = OpenStruct.new(
      purchase_type: 1,
      price_amount_micros: 0,
      price_currency_code: "USD",
      start_time_millis: 1_735_689_600_000,
      order_id: "GPA.noop"
    )

    fake_service = build_fake_service(get_purchase_subscription: verified)
    @service_instance.instance_variable_set(:@service, fake_service)

    webhook = create_webhook

    # notificationType 5 = ON_HOLD → nil → :skipped
    notification = {
      "subscriptionNotification" => {
        "purchaseToken" => "token_noop",
        "subscriptionId" => "sub_001",
        "notificationType" => 5
      }
    }

    result = @service_instance.send(
      :handle_subscription_notification, notification, @instance, webhook, "com.test.app"
    )
    assert_equal :skipped, result
  end

  # ---------------------------------------------------------------------------
  # handle_subscription_notification — CANCEL event creation
  # ---------------------------------------------------------------------------

  test "cancel notification creates CANCEL event" do
    verified = OpenStruct.new(
      purchase_type: 1,
      price_amount_micros: 9_990_000,
      price_currency_code: "USD",
      start_time_millis: 1_735_689_600_000,
      expiry_time_millis: 1_738_368_000_000,
      order_id: "GPA.cancel-test"
    )

    fake_service = build_fake_service(get_purchase_subscription: verified)
    @service_instance.instance_variable_set(:@service, fake_service)

    webhook = create_webhook
    notification = {
      "subscriptionNotification" => {
        "purchaseToken" => "token_cancel_test",
        "subscriptionId" => "sub_premium",
        "notificationType" => 3  # CANCELED
      }
    }

    result = @service_instance.send(
      :handle_subscription_notification, notification, @instance, webhook, "com.test.app"
    )
    assert_equal true, result

    event = PurchaseEvent.find_by(transaction_id: "token_cancel_test")
    assert event
    assert_equal Grovs::Purchases::EVENT_CANCEL, event.event_type
    assert_equal Grovs::Purchases::TYPE_SUBSCRIPTION, event.purchase_type
  end

  # ---------------------------------------------------------------------------
  # handle_subscription_notification — uses shared gateway dedup
  # ---------------------------------------------------------------------------

  test "duplicate subscription RTDN does not create second event" do
    verified = OpenStruct.new(
      purchase_type: 1,
      price_amount_micros: 9_990_000,
      price_currency_code: "USD",
      start_time_millis: 1_735_689_600_000,
      order_id: "GPA.dedup-test"
    )

    fake_service = build_fake_service(get_purchase_subscription: verified)
    @service_instance.instance_variable_set(:@service, fake_service)

    notification = {
      "subscriptionNotification" => {
        "purchaseToken" => "token_dedup_sub",
        "subscriptionId" => "sub_premium",
        "notificationType" => 4  # PURCHASED
      }
    }

    # First call
    webhook1 = create_webhook
    @service_instance.send(
      :handle_subscription_notification, notification, @instance, webhook1, "com.test.app"
    )

    # Second call — should short-circuit
    webhook2 = create_webhook
    assert_no_difference "PurchaseEvent.count" do
      @service_instance.send(
        :handle_subscription_notification, notification, @instance, webhook2, "com.test.app"
      )
    end
  end

  # ---------------------------------------------------------------------------
  # verify_subscription_purchase — error handling
  # ---------------------------------------------------------------------------

  test "returns false when Google API returns auth error" do
    fake_service = Object.new
    fake_service.define_singleton_method(:get_purchase_subscription) do |*_|
      raise Google::Apis::AuthorizationError, "invalid_grant"
    end
    @service_instance.instance_variable_set(:@service, fake_service)

    webhook = create_webhook
    notification = {
      "subscriptionNotification" => {
        "purchaseToken" => "token_auth_err",
        "subscriptionId" => "sub_001",
        "notificationType" => 4
      }
    }

    result = @service_instance.send(
      :handle_subscription_notification, notification, @instance, webhook, "com.test.app"
    )
    assert_equal false, result
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

  def build_fake_service(**responses)
    service = Object.new
    responses.each do |method_name, return_value|
      service.define_singleton_method(method_name) { |*_args| return_value }
    end
    service
  end
end
