require "test_helper"

class GoogleIapService::PurchaseEventHandlingTest < ActiveSupport::TestCase
  fixtures :instances, :projects, :devices

  setup do
    @project = projects(:one)
    @service_instance = GoogleIapService.new
    @service_instance.instance_variable_set(:@service, Object.new)
  end

  # ---------------------------------------------------------------------------
  # Step 1: Validate existing mobile SDK event
  # ---------------------------------------------------------------------------

  test "validates existing unvalidated mobile SDK event" do
    mobile_event = PurchaseEvent.create!(
      project: @project,
      event_type: Grovs::Purchases::EVENT_BUY,
      transaction_id: "token_mobile_sdk",
      original_transaction_id: "token_mobile_sdk",
      product_id: "com.test.premium",
      identifier: "com.test.app",
      price_cents: 999, currency: "USD", usd_price_cents: 999,
      date: Time.current,
      purchase_type: Grovs::Purchases::TYPE_SUBSCRIPTION,
      webhook_validated: false,
      store: false
    )

    result = @service_instance.send(
      :handle_google_purchase_event,
      event_type: Grovs::Purchases::EVENT_BUY,
      project: @project,
      transaction_id: "token_mobile_sdk",
      original_transaction_id: "token_mobile_sdk",
      product_id: "com.test.premium",
      identifier: "com.test.app",
      price_cents: 999,
      currency: "USD",
      date: Time.current,
      purchase_type: Grovs::Purchases::TYPE_SUBSCRIPTION
    )

    assert result
    assert_equal mobile_event.id, result.id
    assert result.webhook_validated, "Should mark mobile event as webhook_validated"
  end

  # ---------------------------------------------------------------------------
  # Step 2: Short-circuit on duplicate webhook-validated event
  # ---------------------------------------------------------------------------

  test "returns existing webhook-validated event without creating duplicate" do
    existing = PurchaseEvent.create!(
      project: @project,
      event_type: Grovs::Purchases::EVENT_BUY,
      transaction_id: "token_webhook_dup",
      original_transaction_id: "token_webhook_dup",
      product_id: "com.test.premium",
      identifier: "com.test.app",
      price_cents: 999, currency: "USD", usd_price_cents: 999,
      date: Time.current,
      purchase_type: Grovs::Purchases::TYPE_SUBSCRIPTION,
      webhook_validated: true,
      store: true,
      store_source: Grovs::Webhooks::GOOGLE
    )

    assert_no_difference "PurchaseEvent.count" do
      result = @service_instance.send(
        :handle_google_purchase_event,
        event_type: Grovs::Purchases::EVENT_BUY,
        project: @project,
        transaction_id: "token_webhook_dup",
        original_transaction_id: "token_webhook_dup",
        product_id: "com.test.premium",
        identifier: "com.test.app",
        price_cents: 999,
        currency: "USD",
        date: Time.current,
        purchase_type: Grovs::Purchases::TYPE_SUBSCRIPTION
      )

      assert_equal existing.id, result.id
    end
  end

  test "short-circuit finds event by original_transaction_id when txn matches" do
    existing = PurchaseEvent.create!(
      project: @project,
      event_type: Grovs::Purchases::EVENT_BUY,
      transaction_id: "token_orig_match",
      original_transaction_id: "token_orig_match",
      product_id: "com.test.premium",
      identifier: "com.test.app",
      price_cents: 999, currency: "USD", usd_price_cents: 999,
      date: Time.current,
      purchase_type: Grovs::Purchases::TYPE_ONE_TIME,
      webhook_validated: true,
      store: true,
      store_source: Grovs::Webhooks::GOOGLE
    )

    assert_no_difference "PurchaseEvent.count" do
      result = @service_instance.send(
        :handle_google_purchase_event,
        event_type: Grovs::Purchases::EVENT_BUY,
        project: @project,
        transaction_id: "token_orig_match",
        original_transaction_id: "token_orig_match",
        product_id: "com.test.premium",
        identifier: "com.test.app",
        price_cents: 999,
        currency: "USD",
        date: Time.current,
        purchase_type: Grovs::Purchases::TYPE_ONE_TIME
      )

      assert_equal existing.id, result.id
    end
  end

  # ---------------------------------------------------------------------------
  # Step 2: original_transaction_id fallback is skipped for bundles
  # ---------------------------------------------------------------------------

  test "does not short-circuit on original_transaction_id when transaction_id differs" do
    # Simulate first bundle item already created
    PurchaseEvent.create!(
      project: @project,
      event_type: Grovs::Purchases::EVENT_BUY,
      transaction_id: "token_bundle:product_a",
      original_transaction_id: "token_bundle",
      product_id: "com.test.product_a",
      identifier: "com.test.app",
      price_cents: 299, currency: "USD", usd_price_cents: 299,
      date: Time.current,
      purchase_type: Grovs::Purchases::TYPE_ONE_TIME,
      webhook_validated: true,
      store: true,
      store_source: Grovs::Webhooks::GOOGLE
    )

    # Second bundle item should NOT match the first via original_transaction_id
    assert_difference "PurchaseEvent.count", 1 do
      result = @service_instance.send(
        :handle_google_purchase_event,
        event_type: Grovs::Purchases::EVENT_BUY,
        project: @project,
        transaction_id: "token_bundle:product_b",
        original_transaction_id: "token_bundle",
        product_id: "com.test.product_b",
        identifier: "com.test.app",
        price_cents: 499,
        currency: "USD",
        date: Time.current,
        purchase_type: Grovs::Purchases::TYPE_ONE_TIME
      )

      assert_equal "com.test.product_b", result.product_id
    end
  end

  # ---------------------------------------------------------------------------
  # Step 3: Creates new event when no existing event found
  # ---------------------------------------------------------------------------

  test "creates new event when no existing event found" do
    assert_difference "PurchaseEvent.count", 1 do
      result = @service_instance.send(
        :handle_google_purchase_event,
        event_type: Grovs::Purchases::EVENT_BUY,
        project: @project,
        transaction_id: "token_new_event",
        original_transaction_id: "token_new_event",
        product_id: "com.test.premium",
        identifier: "com.test.app",
        price_cents: 999,
        currency: "USD",
        date: Time.current,
        purchase_type: Grovs::Purchases::TYPE_SUBSCRIPTION
      )

      assert result
      assert_equal "token_new_event", result.transaction_id
      assert result.webhook_validated
    end
  end

  # ---------------------------------------------------------------------------
  # extract_v2_line_item_quantity
  # ---------------------------------------------------------------------------

  test "extract_v2_line_item_quantity reads from product_offer_details" do
    offer = OpenStruct.new(quantity: 3)
    item = OpenStruct.new(product_offer_details: offer)

    result = @service_instance.send(:extract_v2_line_item_quantity, item)
    assert_equal 3, result
  end

  test "extract_v2_line_item_quantity returns 1 when product_offer_details is nil" do
    item = OpenStruct.new(product_offer_details: nil)

    result = @service_instance.send(:extract_v2_line_item_quantity, item)
    assert_equal 1, result
  end

  test "extract_v2_line_item_quantity returns 1 when quantity is nil" do
    offer = OpenStruct.new(quantity: nil)
    item = OpenStruct.new(product_offer_details: offer)

    result = @service_instance.send(:extract_v2_line_item_quantity, item)
    assert_equal 1, result
  end

  # ---------------------------------------------------------------------------
  # extract_v2_purchase_time
  # ---------------------------------------------------------------------------

  test "extract_v2_purchase_time parses ISO 8601 purchase_completion_time" do
    obj = OpenStruct.new(purchase_completion_time: "2025-01-01T00:00:00Z")

    result = @service_instance.send(:extract_v2_purchase_time, obj)
    assert_equal Time.parse("2025-01-01T00:00:00Z"), result
  end

  test "extract_v2_purchase_time falls back to purchase_time_millis" do
    obj = OpenStruct.new(purchase_time_millis: 1_735_689_600_000)

    result = @service_instance.send(:extract_v2_purchase_time, obj)
    assert_equal Time.at(1_735_689_600), result
  end

  test "extract_v2_purchase_time returns current time when no timestamp" do
    obj = OpenStruct.new

    freeze_time do
      result = @service_instance.send(:extract_v2_purchase_time, obj)
      assert_equal Time.current, result
    end
  end

  test "extract_v2_purchase_time falls back to current time on malformed ISO string" do
    obj = OpenStruct.new(purchase_completion_time: "not-a-date")

    freeze_time do
      result = @service_instance.send(:extract_v2_purchase_time, obj)
      assert_equal Time.current, result
    end
  end
end
