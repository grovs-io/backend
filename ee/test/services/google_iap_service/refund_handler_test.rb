require "test_helper"

class GoogleIapService::RefundHandlerTest < ActiveSupport::TestCase
  fixtures :instances, :projects, :devices, :purchase_events

  setup do
    @project = projects(:one)
    @instance = instances(:one)
    @service_instance = GoogleIapService.new
    @service_instance.instance_variable_set(:@service, Object.new)
  end

  # ---------------------------------------------------------------------------
  # Full refund — subscription
  # ---------------------------------------------------------------------------

  test "full refund of single subscription creates REFUND event" do
    buy = create_buy_event(
      transaction_id: "token_sub_refund",
      original_transaction_id: "token_sub_refund",
      product_id: "com.test.premium",
      purchase_type: Grovs::Purchases::TYPE_SUBSCRIPTION,
      order_id: "GPA.sub-refund-001",
      price_cents: 999
    )

    webhook = create_webhook
    notification = build_voided_notification(
      purchase_token: "token_sub_refund",
      order_id: "GPA.sub-refund-001",
      product_type: 1,
      refund_type: 1
    )

    result = @service_instance.send(:handle_voided_notification, notification, @instance, webhook, "com.test.app")
    assert_equal true, result

    refund = PurchaseEvent.find_by(
      transaction_id: "token_sub_refund_refund",
      event_type: Grovs::Purchases::EVENT_REFUND
    )
    assert refund, "REFUND event should be created"
    assert_equal buy.price_cents, refund.price_cents
    assert_equal buy.product_id, refund.product_id
    assert_equal buy.quantity, refund.quantity
    assert_equal "GPA.sub-refund-001", refund.order_id
    assert refund.revenue_delta.negative?, "REFUND revenue_delta should be negative"
  end

  # ---------------------------------------------------------------------------
  # Full refund — one-time
  # ---------------------------------------------------------------------------

  test "full refund of single one-time product creates REFUND event" do
    buy = create_buy_event(
      transaction_id: "token_ot_refund",
      original_transaction_id: "token_ot_refund",
      product_id: "com.test.gems",
      purchase_type: Grovs::Purchases::TYPE_ONE_TIME,
      order_id: "GPA.ot-refund-001",
      price_cents: 499
    )

    webhook = create_webhook
    notification = build_voided_notification(
      purchase_token: "token_ot_refund",
      order_id: "GPA.ot-refund-001",
      product_type: 2,
      refund_type: 1
    )

    result = @service_instance.send(:handle_voided_notification, notification, @instance, webhook, "com.test.app")
    assert_equal true, result

    refund = PurchaseEvent.find_by(
      transaction_id: "token_ot_refund_refund",
      event_type: Grovs::Purchases::EVENT_REFUND
    )
    assert refund
    assert_equal Grovs::Purchases::TYPE_ONE_TIME, refund.purchase_type
  end

  # ---------------------------------------------------------------------------
  # Refund inherits usd_price_cents from buy event (no re-conversion needed)
  # ---------------------------------------------------------------------------
  #
  # Two failure modes with the old code:
  #   1. Currency service down → usd_price_cents stays nil → revenue_delta is nil → zero impact
  #   2. Currency service up but rate changed → refund uses today's rate, not the buy's rate
  #
  # Fix: copy usd_price_cents from the buy event (same price, same rate).
  # ---------------------------------------------------------------------------

  test "refund gets usd_price_cents from buy event even when currency service is down" do
    buy = create_buy_event(
      transaction_id: "token_usd_outage",
      original_transaction_id: "token_usd_outage",
      product_id: "com.test.premium",
      purchase_type: Grovs::Purchases::TYPE_SUBSCRIPTION,
      order_id: "GPA.usd-outage-001",
      price_cents: 999
    )
    buy.update_columns(usd_price_cents: 1105, currency: "EUR")

    webhook = create_webhook
    notification = build_voided_notification(
      purchase_token: "token_usd_outage",
      order_id: "GPA.usd-outage-001",
      product_type: 1, refund_type: 1
    )

    # Outage: conversion returns nil.
    # Old code: create_new hardcoded usd_price_cents: nil, callback fires but
    # convert_price_to_usd doesn't overwrite on nil → stays nil → zero revenue impact.
    # New code: create_new passes buy's 1105, callback skipped → 1105 preserved.
    CurrencyConversionService.stub(:to_usd_cents, nil) do
      @service_instance.send(:handle_voided_notification, notification, @instance, webhook, "com.test.app")
    end

    refund = PurchaseEvent.find_by(
      transaction_id: "token_usd_outage_refund",
      event_type: Grovs::Purchases::EVENT_REFUND
    )
    assert refund
    assert_equal 1105, refund.usd_price_cents,
      "Refund should have usd_price_cents from buy event despite conversion outage"
    assert_equal(-1105, refund.revenue_delta,
      "revenue_delta should use the copied usd_price_cents, not be nil")
  end

  test "refund uses buy event exchange rate, not current rate" do
    buy = create_buy_event(
      transaction_id: "token_usd_rate",
      original_transaction_id: "token_usd_rate",
      product_id: "com.test.premium",
      purchase_type: Grovs::Purchases::TYPE_SUBSCRIPTION,
      order_id: "GPA.usd-rate-001",
      price_cents: 999
    )
    # Buy was converted at the old rate: 999 EUR cents → 1105 USD cents
    buy.update_columns(usd_price_cents: 1105, currency: "EUR")

    webhook = create_webhook
    notification = build_voided_notification(
      purchase_token: "token_usd_rate",
      order_id: "GPA.usd-rate-001",
      product_type: 1, refund_type: 1
    )

    # Service is up but rate has changed: 999 EUR cents now converts to 1200 USD cents.
    # Old code: before_save fires on new record (will_save_change_to_price_cents? is true),
    # overwrites our 1105 with 1200 → refund at wrong rate.
    # New code: before_save skips new records that already have usd_price_cents → 1105 preserved.
    CurrencyConversionService.stub(:to_usd_cents, 1200) do
      @service_instance.send(:handle_voided_notification, notification, @instance, webhook, "com.test.app")
    end

    refund = PurchaseEvent.find_by(
      transaction_id: "token_usd_rate_refund",
      event_type: Grovs::Purchases::EVENT_REFUND
    )
    assert refund
    assert_equal 1105, refund.usd_price_cents,
      "Refund must use buy event's original rate (1105), not current rate (1200)"
    assert_equal(-1105, refund.revenue_delta,
      "revenue_delta must reverse the exact amount that was recorded on buy")
  end

  # ---------------------------------------------------------------------------
  # Full refund of a bundle — 2 BUY events → 2 REFUND events
  # ---------------------------------------------------------------------------

  test "full refund of bundle creates REFUND event for each BUY" do
    create_buy_event(
      transaction_id: "token_bundle:product_a",
      original_transaction_id: "token_bundle",
      product_id: "com.test.product_a",
      purchase_type: Grovs::Purchases::TYPE_ONE_TIME,
      order_id: "GPA.bundle-refund-001",
      price_cents: 299
    )
    create_buy_event(
      transaction_id: "token_bundle:product_b",
      original_transaction_id: "token_bundle",
      product_id: "com.test.product_b",
      purchase_type: Grovs::Purchases::TYPE_ONE_TIME,
      order_id: "GPA.bundle-refund-001",
      price_cents: 499
    )

    webhook = create_webhook
    notification = build_voided_notification(
      purchase_token: "token_bundle",
      order_id: "GPA.bundle-refund-001",
      product_type: 2,
      refund_type: 1
    )

    result = @service_instance.send(:handle_voided_notification, notification, @instance, webhook, "com.test.app")
    assert_equal true, result

    refunds = PurchaseEvent.where(
      event_type: Grovs::Purchases::EVENT_REFUND,
      order_id: "GPA.bundle-refund-001"
    )
    assert_equal 2, refunds.count, "Should create 2 REFUND events for 2-product bundle"

    refund_a = refunds.find_by(product_id: "com.test.product_a")
    refund_b = refunds.find_by(product_id: "com.test.product_b")
    assert_equal 299, refund_a.price_cents
    assert_equal 499, refund_b.price_cents
  end

  # ---------------------------------------------------------------------------
  # N+1 prevention: prefetch_refunded_quantities uses single query for bundle
  # ---------------------------------------------------------------------------

  test "full refund of bundle prefetches refunded quantities in one query" do
    3.times do |i|
      create_buy_event(
        transaction_id: "token_n1:product_#{i}",
        original_transaction_id: "token_n1",
        product_id: "com.test.product_#{i}",
        purchase_type: Grovs::Purchases::TYPE_ONE_TIME,
        order_id: "GPA.n1-test",
        price_cents: 100
      )
    end

    webhook = create_webhook
    notification = build_voided_notification(
      purchase_token: "token_n1",
      order_id: "GPA.n1-test",
      product_type: 2,
      refund_type: 1
    )

    sum_queries = 0
    callback = lambda { |_name, _start, _finish, _id, payload|
      sql = payload[:sql]
      sum_queries += 1 if sql.include?("purchase_events") && sql.include?("SUM") && sql.include?("GROUP BY")
    }

    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
      @service_instance.send(:handle_voided_notification, notification, @instance, webhook, "com.test.app")
    end

    assert_equal 1, sum_queries, "Should prefetch refunded quantities in a single grouped query, not N"

    refunds = PurchaseEvent.where(event_type: Grovs::Purchases::EVENT_REFUND, order_id: "GPA.n1-test")
    assert_equal 3, refunds.count
  end

  # ---------------------------------------------------------------------------
  # prefetch_refunded_quantities avoids cross-product matching
  # ---------------------------------------------------------------------------
  #
  # The bug: WHERE original_transaction_id IN (a,b) AND product_id IN (x,y)
  # creates a cross-product that also matches (a,y) and (b,x).
  #
  # The fix: row-value IN — WHERE (original_transaction_id, product_id) IN ((a,x),(b,y))
  # matches only exact pairs.
  # ---------------------------------------------------------------------------

  test "prefetch excludes phantom cross-product matches while keeping legitimate ones" do
    # Setup: two buys from different transactions with different products.
    # Input pairs to prefetch: (txn_A, prod_X) and (txn_B, prod_Y)
    #
    # Cross-product WHERE IN would expand to:
    #   original_transaction_id IN ('txn_A','txn_B') AND product_id IN ('prod_X','prod_Y')
    # which also matches the phantom pairs (txn_A, prod_Y) and (txn_B, prod_X).
    buy_a = create_buy_event(
      transaction_id: "txn_A", original_transaction_id: "txn_A",
      product_id: "prod_X", purchase_type: Grovs::Purchases::TYPE_ONE_TIME,
      order_id: "GPA.cross-a", price_cents: 100, quantity: 5
    )
    buy_b = create_buy_event(
      transaction_id: "txn_B", original_transaction_id: "txn_B",
      product_id: "prod_Y", purchase_type: Grovs::Purchases::TYPE_ONE_TIME,
      order_id: "GPA.cross-b", price_cents: 200, quantity: 3
    )

    # Legitimate refund for (txn_A, prod_X) — should be counted
    create_refund(original_transaction_id: "txn_A", product_id: "prod_X", quantity: 2)

    # Phantom-match refunds — exist in DB but are NOT in our input pairs.
    # A cross-product WHERE IN would pull these in; row-value IN must not.
    create_refund(original_transaction_id: "txn_A", product_id: "prod_Y", quantity: 3)
    create_refund(original_transaction_id: "txn_B", product_id: "prod_X", quantity: 1)

    result = @service_instance.send(:prefetch_refunded_quantities, [buy_a, buy_b])

    # Legitimate pair is counted
    assert_equal 2, result[["txn_A", "prod_X"]], "Should count legitimate refund for (txn_A, prod_X)"

    # Phantom pairs are excluded
    assert_nil result[["txn_A", "prod_Y"]], "Must not cross-product match (txn_A, prod_Y)"
    assert_nil result[["txn_B", "prod_X"]], "Must not cross-product match (txn_B, prod_X)"

    # No refund exists yet for (txn_B, prod_Y)
    assert_nil result[["txn_B", "prod_Y"]], "No refund exists for (txn_B, prod_Y)"

    assert_equal 1, result.size, "Exactly one input pair has a matching refund"
  end

  test "cross-product exclusion produces correct refund quantities end-to-end" do
    # Scenario: two separate single-product purchases share an order_id
    # (e.g. re-purchased after a previous refund, same order_id reused by Google).
    #
    # buy_a: (txn_A, prod_X) qty 5 — previously had 2 refunded via phantom pair (txn_A, prod_Y)
    # buy_b: (txn_B, prod_Y) qty 3 — no prior refunds
    #
    # With cross-product bug: prefetch would return {[txn_A, prod_Y] => 3},
    # and determine_refund_quantity for buy_b would see 3 already refunded for
    # (txn_B, prod_Y)? No — the lookup key wouldn't match. BUT for buy_a,
    # the legitimate (txn_A, prod_X) refund count could be polluted if a
    # phantom (txn_B, prod_X) refund exists, inflating already_refunded.
    #
    # Real danger: buy_a has qty 5, legitimate refund of 2 for (txn_A, prod_X),
    # phantom refund of 1 for (txn_B, prod_X). With cross-product, the query
    # would NOT mix these (GROUP BY separates them), but it's still wrong to
    # fetch data we don't need. More importantly, if someone later changes the
    # code to aggregate differently, the phantom data would corrupt results.
    #
    # This test verifies the full refund path creates correct quantities.
    create_buy_event(
      transaction_id: "txn_cp_A", original_transaction_id: "txn_cp_A",
      product_id: "prod_cp_X", purchase_type: Grovs::Purchases::TYPE_ONE_TIME,
      order_id: "GPA.cross-e2e", price_cents: 100, quantity: 5
    )
    create_buy_event(
      transaction_id: "txn_cp_B", original_transaction_id: "txn_cp_B",
      product_id: "prod_cp_Y", purchase_type: Grovs::Purchases::TYPE_ONE_TIME,
      order_id: "GPA.cross-e2e", price_cents: 200, quantity: 3
    )

    # Prior partial refund for buy_a: 2 of 5 already refunded
    create_refund(original_transaction_id: "txn_cp_A", product_id: "prod_cp_X",
                  quantity: 2, transaction_id: "txn_cp_A_partial_refund",
                  order_id: "GPA.cross-e2e")

    # Phantom refund that a cross-product query would pick up
    create_refund(original_transaction_id: "txn_cp_A", product_id: "prod_cp_Y",
                  quantity: 3, transaction_id: "txn_cp_A_prod_Y_phantom",
                  order_id: "GPA.other-order")

    # Full refund RTDN for the shared order
    webhook = create_webhook
    notification = build_voided_notification(
      purchase_token: "txn_cp_A", order_id: "GPA.cross-e2e",
      product_type: 2, refund_type: 1
    )

    @service_instance.send(:handle_voided_notification, notification, @instance, webhook, "com.test.app")

    refund_a = PurchaseEvent.find_by(
      transaction_id: "txn_cp_A_refund",
      event_type: Grovs::Purchases::EVENT_REFUND
    )
    refund_b = PurchaseEvent.find_by(
      transaction_id: "txn_cp_B_refund",
      event_type: Grovs::Purchases::EVENT_REFUND
    )

    assert refund_a, "Should create refund for buy_a"
    assert_equal 3, refund_a.quantity, "buy_a: 5 bought - 2 already refunded = 3 remaining"

    assert refund_b, "Should create refund for buy_b"
    assert_equal 3, refund_b.quantity, "buy_b: 3 bought - 0 already refunded = 3 remaining"
  end

  # ---------------------------------------------------------------------------
  # Partial quantity refund
  # ---------------------------------------------------------------------------

  test "partial quantity refund uses voidedQuantity from API" do
    create_buy_event(
      transaction_id: "token_qty_partial",
      original_transaction_id: "token_qty_partial",
      product_id: "com.test.gems",
      purchase_type: Grovs::Purchases::TYPE_ONE_TIME,
      order_id: "GPA.qty-partial-001",
      price_cents: 100,
      quantity: 5
    )

    voided_response = OpenStruct.new(
      voided_purchases: [
        OpenStruct.new(purchase_token: "token_qty_partial", voided_quantity: 2)
      ]
    )

    fake_service = Object.new
    fake_service.define_singleton_method(:list_purchase_voidedpurchases) { |*_args, **_kwargs| voided_response }

    @service_instance.instance_variable_set(:@service, fake_service)

    webhook = create_webhook
    notification = build_voided_notification(
      purchase_token: "token_qty_partial",
      order_id: "GPA.qty-partial-001",
      product_type: 2,
      refund_type: 2
    )

    result = @service_instance.send(:handle_voided_notification, notification, @instance, webhook, "com.test.app")
    assert_equal true, result

    refund = PurchaseEvent.find_by(
      transaction_id: "token_qty_partial_refund",
      event_type: Grovs::Purchases::EVENT_REFUND
    )
    assert refund
    assert_equal 2, refund.quantity, "Refund quantity should match voidedQuantity"
  end

  # ---------------------------------------------------------------------------
  # fetch_voided_quantity passes start_time to scope the API call
  # ---------------------------------------------------------------------------

  test "fetch_voided_quantity passes start_time to scope results to recent window" do
    create_buy_event(
      transaction_id: "token_start_time",
      original_transaction_id: "token_start_time",
      product_id: "com.test.gems",
      purchase_type: Grovs::Purchases::TYPE_ONE_TIME,
      order_id: "GPA.start-time-001",
      price_cents: 100,
      quantity: 5
    )

    received_kwargs = nil
    voided_response = OpenStruct.new(
      voided_purchases: [
        OpenStruct.new(purchase_token: "token_start_time", voided_quantity: 1)
      ]
    )

    fake_service = Object.new
    fake_service.define_singleton_method(:list_purchase_voidedpurchases) do |*_args, **kwargs|
      received_kwargs = kwargs
      voided_response
    end
    @service_instance.instance_variable_set(:@service, fake_service)

    webhook = create_webhook
    notification = build_voided_notification(
      purchase_token: "token_start_time",
      order_id: "GPA.start-time-001",
      product_type: 2,
      refund_type: 2
    )

    freeze_time do
      @service_instance.send(:handle_voided_notification, notification, @instance, webhook, "com.test.app")

      expected_start_time = (Time.current - 30.days).to_i * 1000
      assert_equal expected_start_time, received_kwargs[:start_time],
        "Should pass start_time scoped to 30 days ago"
    end
  end

  # ---------------------------------------------------------------------------
  # Refund for purchase not in DB
  # ---------------------------------------------------------------------------

  test "returns false when no BUY events found" do
    webhook = create_webhook
    notification = build_voided_notification(
      purchase_token: "nonexistent_token",
      order_id: "GPA.nonexistent-001",
      product_type: 1,
      refund_type: 1
    )

    result = @service_instance.send(:handle_voided_notification, notification, @instance, webhook, "com.test.app")
    assert_equal false, result

    refunds = PurchaseEvent.where(event_type: Grovs::Purchases::EVENT_REFUND, order_id: "GPA.nonexistent-001")
    assert_equal 0, refunds.count
  end

  # ---------------------------------------------------------------------------
  # Idempotent — duplicate RTDN
  # ---------------------------------------------------------------------------

  test "duplicate RTDN creates only one REFUND event" do
    create_buy_event(
      transaction_id: "token_idempotent",
      original_transaction_id: "token_idempotent",
      product_id: "com.test.premium",
      purchase_type: Grovs::Purchases::TYPE_SUBSCRIPTION,
      order_id: "GPA.idempotent-001",
      price_cents: 999
    )

    webhook = create_webhook
    notification = build_voided_notification(
      purchase_token: "token_idempotent",
      order_id: "GPA.idempotent-001",
      product_type: 1,
      refund_type: 1
    )

    @service_instance.send(:handle_voided_notification, notification, @instance, webhook, "com.test.app")

    webhook2 = create_webhook
    @service_instance.send(:handle_voided_notification, notification, @instance, webhook2, "com.test.app")

    refunds = PurchaseEvent.where(
      transaction_id: "token_idempotent_refund",
      event_type: Grovs::Purchases::EVENT_REFUND
    )
    assert_equal 1, refunds.count, "Duplicate RTDN should not create second REFUND"
  end

  # ---------------------------------------------------------------------------
  # Partial refund then full refund
  # ---------------------------------------------------------------------------

  test "partial refund then full refund creates correct quantities" do
    buy = create_buy_event(
      transaction_id: "token_partial_full",
      original_transaction_id: "token_partial_full",
      product_id: "com.test.gems",
      purchase_type: Grovs::Purchases::TYPE_ONE_TIME,
      order_id: "GPA.partial-full-001",
      price_cents: 100,
      quantity: 5
    )

    # First: create a partial refund manually (simulating a previous partial refund)
    PurchaseEvent.create!(
      project: @project,
      event_type: Grovs::Purchases::EVENT_REFUND,
      transaction_id: "token_partial_full_partial_refund",
      original_transaction_id: "token_partial_full",
      product_id: "com.test.gems",
      price_cents: 100,
      currency: "USD",
      usd_price_cents: 100,
      date: Time.current,
      purchase_type: Grovs::Purchases::TYPE_ONE_TIME,
      order_id: "GPA.partial-full-001",
      quantity: 2,
      webhook_validated: true,
      store: true,
      store_source: Grovs::Webhooks::GOOGLE
    )

    # Now: full refund RTDN arrives
    webhook = create_webhook
    notification = build_voided_notification(
      purchase_token: "token_partial_full",
      order_id: "GPA.partial-full-001",
      product_type: 2,
      refund_type: 1
    )

    @service_instance.send(:handle_voided_notification, notification, @instance, webhook, "com.test.app")

    refund = PurchaseEvent.find_by(
      transaction_id: "token_partial_full_refund",
      event_type: Grovs::Purchases::EVENT_REFUND
    )
    assert refund
    assert_equal 3, refund.quantity, "Full refund should refund remaining 5-2=3"
  end

  # ---------------------------------------------------------------------------
  # Fallback to transaction_id for pre-migration events
  # ---------------------------------------------------------------------------

  test "falls back to transaction_id when order_id not found" do
    create_buy_event(
      transaction_id: "token_premigration",
      original_transaction_id: "token_premigration",
      product_id: "com.test.premium",
      purchase_type: Grovs::Purchases::TYPE_SUBSCRIPTION,
      order_id: nil,
      price_cents: 999
    )

    webhook = create_webhook
    notification = build_voided_notification(
      purchase_token: "token_premigration",
      order_id: "GPA.unknown-order",
      product_type: 1,
      refund_type: 1
    )

    result = @service_instance.send(:handle_voided_notification, notification, @instance, webhook, "com.test.app")
    assert_equal true, result

    refund = PurchaseEvent.find_by(
      transaction_id: "token_premigration_refund",
      event_type: Grovs::Purchases::EVENT_REFUND
    )
    assert refund, "Should find BUY via transaction_id fallback and create REFUND"
  end

  # ---------------------------------------------------------------------------
  # Missing required fields
  # ---------------------------------------------------------------------------

  test "returns false when purchaseToken missing" do
    webhook = create_webhook
    notification = {
      "voidedPurchaseNotification" => {
        "orderId" => "GPA.order-001",
        "productType" => 1,
        "refundType" => 1
      }
    }

    result = @service_instance.send(:handle_voided_notification, notification, @instance, webhook, "com.test.app")
    assert_equal false, result
  end

  test "returns false when orderId missing" do
    webhook = create_webhook
    notification = {
      "voidedPurchaseNotification" => {
        "purchaseToken" => "some_token",
        "productType" => 1,
        "refundType" => 1
      }
    }

    result = @service_instance.send(:handle_voided_notification, notification, @instance, webhook, "com.test.app")
    assert_equal false, result
  end

  private

  def create_buy_event(transaction_id:, original_transaction_id:, product_id:, purchase_type:, order_id:, price_cents:, quantity: 1)
    PurchaseEvent.create!(
      project: @project,
      event_type: Grovs::Purchases::EVENT_BUY,
      transaction_id: transaction_id,
      original_transaction_id: original_transaction_id,
      product_id: product_id,
      identifier: "com.test.app",
      price_cents: price_cents,
      currency: "USD",
      usd_price_cents: price_cents,
      date: Time.current,
      purchase_type: purchase_type,
      order_id: order_id,
      quantity: quantity,
      webhook_validated: true,
      store: true,
      store_source: Grovs::Webhooks::GOOGLE
    )
  end

  def create_webhook
    IapWebhookMessage.create!(
      payload: "test",
      notification_type: "UNKNOWN",
      source: Grovs::Webhooks::GOOGLE,
      instance: @instance
    )
  end

  def create_refund(original_transaction_id:, product_id:, quantity:, transaction_id: nil, order_id: nil)
    transaction_id ||= "#{original_transaction_id}_#{product_id}_refund_#{SecureRandom.hex(4)}"
    PurchaseEvent.create!(
      project: @project,
      event_type: Grovs::Purchases::EVENT_REFUND,
      transaction_id: transaction_id,
      original_transaction_id: original_transaction_id,
      product_id: product_id,
      price_cents: 100, currency: "USD", usd_price_cents: 100,
      date: Time.current,
      purchase_type: Grovs::Purchases::TYPE_ONE_TIME,
      order_id: order_id || "GPA.refund",
      quantity: quantity,
      webhook_validated: true, store: true,
      store_source: Grovs::Webhooks::GOOGLE
    )
  end

  def build_voided_notification(purchase_token:, order_id:, product_type:, refund_type:)
    {
      "voidedPurchaseNotification" => {
        "purchaseToken" => purchase_token,
        "orderId" => order_id,
        "productType" => product_type,
        "refundType" => refund_type
      }
    }
  end
end
