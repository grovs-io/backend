require "test_helper"

class PurchaseEventCreatorTest < ActiveSupport::TestCase
  fixtures :instances, :projects, :devices, :visitors, :purchase_events, :subscription_states

  setup do
    @creator = PurchaseEventCreator.new
    @project = projects(:one)
    @device = devices(:ios_device)
  end

  # --- validate_existing ---

  test "validate_existing updates SDK event with webhook data" do
    sdk_event = PurchaseEvent.create!(
      project: @project,
      event_type: Grovs::Purchases::EVENT_BUY,
      transaction_id: "sdk_txn_100",
      original_transaction_id: "sdk_orig_100",
      product_id: "com.test.old",
      price_cents: 0,
      currency: "USD",
      date: 1.day.ago,
      webhook_validated: false,
      processed: false,
      purchase_type: Grovs::Purchases::TYPE_SUBSCRIPTION
    )

    result = @creator.validate_existing(sdk_event, store_source: Grovs::Webhooks::APPLE,
      identifier: "com.test.app",
      original_transaction_id: "sdk_orig_100",
      product_id: "com.test.premium",
      date: Time.current,
      expires_date: 30.days.from_now,
      purchase_type: Grovs::Purchases::TYPE_SUBSCRIPTION,
      price_cents: 999,
      currency: "USD"
    )

    assert_equal sdk_event, result
    sdk_event.reload
    assert sdk_event.webhook_validated?
    assert sdk_event.store?
    assert_equal Grovs::Webhooks::APPLE, sdk_event.store_source
    assert_equal "com.test.premium", sdk_event.product_id
    assert_equal 999, sdk_event.price_cents
  end

  test "validate_existing preserves SDK price for one-time purchases when SDK price is set" do
    sdk_event = PurchaseEvent.create!(
      project: @project,
      event_type: Grovs::Purchases::EVENT_BUY,
      transaction_id: "sdk_txn_ot",
      original_transaction_id: "sdk_txn_ot",
      product_id: "com.test.gem_pack",
      price_cents: 299,
      currency: "USD",
      date: 1.day.ago,
      webhook_validated: false,
      processed: false,
      purchase_type: Grovs::Purchases::TYPE_ONE_TIME
    )

    @creator.validate_existing(sdk_event, store_source: Grovs::Webhooks::GOOGLE,
      identifier: "com.test.app",
      original_transaction_id: "sdk_txn_ot",
      product_id: "com.test.gem_pack",
      date: Time.current,
      expires_date: nil,
      purchase_type: Grovs::Purchases::TYPE_ONE_TIME,
      price_cents: 399,
      currency: "USD"
    )

    sdk_event.reload
    assert_equal 299, sdk_event.price_cents, "SDK price should be preserved for one-time with existing price"
  end

  test "validate_existing dispatches job for unprocessed event" do
    sdk_event = PurchaseEvent.create!(
      project: @project,
      event_type: Grovs::Purchases::EVENT_BUY,
      transaction_id: "sdk_txn_unproc",
      original_transaction_id: "sdk_txn_unproc",
      product_id: "com.test.premium",
      price_cents: 999,
      currency: "USD",
      date: 1.day.ago,
      webhook_validated: false,
      processed: false,
      purchase_type: Grovs::Purchases::TYPE_SUBSCRIPTION
    )

    dispatched_args = nil
    stub = ->(*args) { dispatched_args = args }

    ProcessPurchaseEventJob.stub(:perform_async, stub) do
      @creator.validate_existing(sdk_event, store_source: Grovs::Webhooks::APPLE,
        identifier: "com.test.app",
        original_transaction_id: "sdk_txn_unproc",
        product_id: "com.test.premium",
        date: Time.current,
        expires_date: nil,
        purchase_type: Grovs::Purchases::TYPE_SUBSCRIPTION,
        price_cents: 999,
        currency: "USD"
      )
    end

    assert_not_nil dispatched_args, "ProcessPurchaseEventJob should have been dispatched"
    assert_equal [sdk_event.id], dispatched_args
  end

  test "validate_existing dispatches job with old_usd when price changes on processed event" do
    processed_event = PurchaseEvent.create!(
      project: @project,
      event_type: Grovs::Purchases::EVENT_BUY,
      transaction_id: "sdk_txn_price_change",
      original_transaction_id: "sdk_txn_price_change",
      product_id: "com.test.premium",
      price_cents: 500,
      currency: "USD",
      usd_price_cents: 500,
      date: 1.day.ago,
      webhook_validated: false,
      processed: true,
      purchase_type: Grovs::Purchases::TYPE_SUBSCRIPTION
    )

    dispatched_args = nil
    stub = ->(*args) { dispatched_args = args }

    ProcessPurchaseEventJob.stub(:perform_async, stub) do
      @creator.validate_existing(processed_event, store_source: Grovs::Webhooks::APPLE,
        identifier: "com.test.app",
        original_transaction_id: "sdk_txn_price_change",
        product_id: "com.test.premium",
        date: Time.current,
        expires_date: nil,
        purchase_type: Grovs::Purchases::TYPE_SUBSCRIPTION,
        price_cents: 999,
        currency: "USD"
      )
    end

    assert_not_nil dispatched_args, "Should dispatch job for revenue correction"
    assert_equal processed_event.id, dispatched_args[0]
    assert_equal 500, dispatched_args[1], "Should pass old_usd_price_cents for correction"
  end

  test "validate_existing does not dispatch job for processed event with same price" do
    processed_event = PurchaseEvent.create!(
      project: @project,
      event_type: Grovs::Purchases::EVENT_BUY,
      transaction_id: "sdk_txn_same_price",
      original_transaction_id: "sdk_txn_same_price",
      product_id: "com.test.premium",
      price_cents: 999,
      currency: "USD",
      usd_price_cents: 999,
      date: 1.day.ago,
      webhook_validated: true,
      processed: true,
      purchase_type: Grovs::Purchases::TYPE_SUBSCRIPTION
    )

    dispatched = false
    stub = ->(*_args) { dispatched = true }

    ProcessPurchaseEventJob.stub(:perform_async, stub) do
      @creator.validate_existing(processed_event, store_source: Grovs::Webhooks::APPLE,
        identifier: "com.test.app",
        original_transaction_id: "sdk_txn_same_price",
        product_id: "com.test.premium",
        date: Time.current,
        expires_date: nil,
        purchase_type: Grovs::Purchases::TYPE_SUBSCRIPTION,
        price_cents: 999,
        currency: "USD"
      )
    end

    assert_not dispatched, "Should not dispatch job when price unchanged on processed event"
  end

  # --- create_new ---

  test "create_new creates purchase event with attribution from subscription_states" do
    # subscription_states fixture has orig_txn_001 → ios_device
    assert_difference "PurchaseEvent.count", 1 do
      event = @creator.create_new(
        event_type: Grovs::Purchases::EVENT_BUY,
        project: @project,
        store_source: Grovs::Webhooks::APPLE,
        transaction_id: "new_txn_from_renewal",
        original_transaction_id: "orig_txn_001",
        product_id: "com.test.premium",
        identifier: "com.test.app",
        price_cents: 999,
        currency: "USD",
        date: Time.current,
        expires_date: 30.days.from_now,
        purchase_type: Grovs::Purchases::TYPE_SUBSCRIPTION
      )

      assert event.persisted?
      assert event.webhook_validated?
      assert_equal @device.id, event.device_id, "Should attribute to device from subscription_states"
      assert_equal Grovs::Webhooks::APPLE, event.store_source
    end
  end

  test "create_new creates event without attribution for unknown transaction" do
    assert_difference "PurchaseEvent.count", 1 do
      event = @creator.create_new(
        event_type: Grovs::Purchases::EVENT_BUY,
        project: @project,
        store_source: Grovs::Webhooks::GOOGLE,
        transaction_id: "brand_new_txn",
        original_transaction_id: "brand_new_orig",
        product_id: "com.test.new_product",
        identifier: "com.test.app",
        price_cents: 499,
        currency: "EUR",
        date: Time.current,
        purchase_type: Grovs::Purchases::TYPE_ONE_TIME
      )

      assert event.persisted?
      assert_nil event.device_id
      assert_nil event.link_id
      assert_equal Grovs::Webhooks::GOOGLE, event.store_source
    end
  end

  test "create_new returns existing event on duplicate transaction" do
    # Create the first event explicitly so we control all fields
    first = PurchaseEvent.create!(
      project: @project,
      event_type: Grovs::Purchases::EVENT_BUY,
      transaction_id: "dedup_txn_001",
      original_transaction_id: "dedup_orig_001",
      product_id: "com.test.premium",
      identifier: "com.test.app",
      price_cents: 999,
      currency: "USD",
      date: Time.current,
      webhook_validated: true,
      store: true,
      store_source: Grovs::Webhooks::APPLE,
      purchase_type: Grovs::Purchases::TYPE_SUBSCRIPTION
    )

    assert_no_difference "PurchaseEvent.count" do
      result = @creator.create_new(
        event_type: Grovs::Purchases::EVENT_BUY,
        project: @project,
        store_source: Grovs::Webhooks::APPLE,
        transaction_id: "dedup_txn_001",
        original_transaction_id: "dedup_orig_001",
        product_id: "com.test.premium",
        identifier: "com.test.app",
        price_cents: 999,
        currency: "USD",
        date: Time.current,
        purchase_type: Grovs::Purchases::TYPE_SUBSCRIPTION
      )

      assert_equal first.id, result.id, "Should return existing event on duplicate"
    end
  end
end
