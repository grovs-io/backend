require "test_helper"

class PurchaseEventTest < ActiveSupport::TestCase
  fixtures :purchase_events, :projects, :devices, :instances

  # === validations ===

  test "valid buy event passes validation" do
    pe = purchase_events(:buy_event)
    assert pe.valid?
  end

  test "invalid event_type fails validation" do
    pe = purchase_events(:buy_event)
    pe.event_type = "invalid_type"
    assert_not pe.valid?
    assert pe.errors[:event_type].any?
  end

  test "blank event_type fails validation" do
    pe = purchase_events(:buy_event)
    pe.event_type = nil
    assert_not pe.valid?
  end

  test "invalid purchase_type fails validation" do
    pe = purchase_events(:buy_event)
    pe.purchase_type = "invalid_type"
    assert_not pe.valid?
    assert pe.errors[:purchase_type].any?
  end

  test "nil purchase_type passes validation" do
    pe = purchase_events(:buy_event)
    pe.purchase_type = nil
    assert pe.valid?
  end

  test "negative price_cents fails validation" do
    pe = purchase_events(:buy_event)
    pe.price_cents = -1
    assert_not pe.valid?
    assert pe.errors[:price_cents].any?
  end

  test "zero price_cents passes validation" do
    pe = purchase_events(:buy_event)
    pe.price_cents = 0
    assert pe.valid?
  end

  test "nil price_cents passes validation" do
    pe = purchase_events(:buy_event)
    pe.price_cents = nil
    assert pe.valid?
  end

  test "invalid store_source fails validation" do
    pe = purchase_events(:buy_event)
    pe.store_source = "invalid_store"
    assert_not pe.valid?
    assert pe.errors[:store_source].any?
  end

  test "nil store_source passes validation" do
    pe = purchase_events(:buy_event)
    pe.store_source = nil
    assert pe.valid?
  end

  # === store_platform ===

  test "store_platform returns ios for apple webhook" do
    pe = purchase_events(:buy_event)
    pe.store_source = Grovs::Webhooks::APPLE
    assert_equal Grovs::Platforms::IOS, pe.store_platform
  end

  test "store_platform returns android for google webhook" do
    pe = purchase_events(:buy_event)
    pe.store_source = Grovs::Webhooks::GOOGLE
    assert_equal Grovs::Platforms::ANDROID, pe.store_platform
  end

  test "store_platform returns nil for nil store_source" do
    pe = purchase_events(:buy_event)
    pe.store_source = nil
    assert_nil pe.store_platform
  end

  # === buy? ===

  test "buy? returns true for buy event" do
    pe = purchase_events(:buy_event)
    assert pe.buy?
  end

  test "buy? returns true for refund_reversed event" do
    pe = purchase_events(:buy_event)
    pe.event_type = Grovs::Purchases::EVENT_REFUND_REVERSED
    assert pe.buy?
  end

  test "buy? returns false for cancel event" do
    pe = purchase_events(:cancel_event)
    assert_not pe.buy?
  end

  test "buy? returns false for refund event" do
    pe = purchase_events(:refund_event)
    assert_not pe.buy?
  end

  # === cancellation? ===

  test "cancellation? returns true for cancel event" do
    pe = purchase_events(:cancel_event)
    assert pe.cancellation?
  end

  test "cancellation? returns true for refund on one_time purchase" do
    pe = purchase_events(:refund_event)
    pe.event_type = Grovs::Purchases::EVENT_REFUND
    pe.purchase_type = Grovs::Purchases::TYPE_ONE_TIME
    assert pe.cancellation?
  end

  test "cancellation? returns false for refund on subscription" do
    pe = purchase_events(:refund_event)
    pe.event_type = Grovs::Purchases::EVENT_REFUND
    pe.purchase_type = Grovs::Purchases::TYPE_SUBSCRIPTION
    assert_not pe.cancellation?
  end

  test "cancellation? returns true for refund on rental purchase" do
    pe = purchase_events(:refund_event)
    pe.event_type = Grovs::Purchases::EVENT_REFUND
    pe.purchase_type = Grovs::Purchases::TYPE_RENTAL
    assert pe.cancellation?
  end

  test "cancellation? returns false for buy event" do
    pe = purchase_events(:buy_event)
    assert_not pe.cancellation?
  end

  test "cancellation? returns false for refund_reversed event" do
    pe = purchase_events(:buy_event)
    pe.event_type = Grovs::Purchases::EVENT_REFUND_REVERSED
    assert_not pe.cancellation?
  end

  # === revenue_delta ===

  test "revenue_delta returns positive cents for buy event" do
    pe = purchase_events(:buy_event)
    assert_equal 999, pe.revenue_delta
  end

  test "revenue_delta returns positive cents for refund_reversed event" do
    pe = purchase_events(:buy_event)
    pe.event_type = Grovs::Purchases::EVENT_REFUND_REVERSED
    pe.usd_price_cents = 500
    assert_equal 500, pe.revenue_delta
  end

  test "revenue_delta returns negative cents for refund event" do
    pe = purchase_events(:refund_event)
    assert_equal(-499, pe.revenue_delta)
  end

  test "revenue_delta returns nil for cancel on subscription" do
    pe = purchase_events(:cancel_event)
    pe.purchase_type = Grovs::Purchases::TYPE_SUBSCRIPTION
    assert_nil pe.revenue_delta
  end

  test "revenue_delta returns negative cents for cancel on one_time" do
    pe = purchase_events(:cancel_event)
    pe.purchase_type = Grovs::Purchases::TYPE_ONE_TIME
    assert_equal(-999, pe.revenue_delta)
  end

  test "revenue_delta returns nil when usd_price_cents is zero" do
    pe = purchase_events(:buy_event)
    pe.usd_price_cents = 0
    assert_nil pe.revenue_delta
  end

  test "revenue_delta accepts custom cents parameter" do
    pe = purchase_events(:buy_event)
    assert_equal 1500, pe.revenue_delta(1500)
  end

  test "revenue_delta with custom cents for refund returns negative" do
    pe = purchase_events(:refund_event)
    assert_equal(-2000, pe.revenue_delta(2000))
  end

  # EE-dependent tests (assign_unique_transaction_id, serialization,
  # convert_price_to_usd callback) are in ee/test/models/purchase_event_ee_test.rb

  test "revenue_delta returns negative cents for cancel on rental" do
    pe = purchase_events(:cancel_event)
    pe.purchase_type = Grovs::Purchases::TYPE_RENTAL
    assert_equal(-999, pe.revenue_delta)
  end

  # === quantity-aware revenue_delta ===

  test "revenue_delta multiplies by quantity for buy event" do
    pe = purchase_events(:buy_event)
    pe.quantity = 3
    assert_equal 999 * 3, pe.revenue_delta
  end

  test "revenue_delta multiplies by quantity for refund event" do
    pe = purchase_events(:refund_event)
    pe.quantity = 2
    assert_equal(-(499 * 2), pe.revenue_delta)
  end

  test "revenue_delta with quantity 1 is backward compatible" do
    pe = purchase_events(:buy_event)
    assert_equal 1, pe.quantity
    assert_equal 999, pe.revenue_delta
  end

  test "revenue_delta with custom cents and quantity" do
    pe = purchase_events(:buy_event)
    pe.quantity = 5
    assert_equal 500 * 5, pe.revenue_delta(500)
  end

  test "revenue_delta for cancel one_time with quantity" do
    pe = purchase_events(:cancel_event)
    pe.purchase_type = Grovs::Purchases::TYPE_ONE_TIME
    pe.quantity = 3
    assert_equal(-(999 * 3), pe.revenue_delta)
  end

  test "revenue_delta for cancel subscription ignores quantity" do
    pe = purchase_events(:cancel_event)
    pe.purchase_type = Grovs::Purchases::TYPE_SUBSCRIPTION
    pe.quantity = 5
    assert_nil pe.revenue_delta
  end

  test "revenue_delta for refund_reversed with quantity" do
    pe = purchase_events(:buy_event)
    pe.event_type = Grovs::Purchases::EVENT_REFUND_REVERSED
    pe.usd_price_cents = 500
    pe.quantity = 2
    assert_equal 500 * 2, pe.revenue_delta
  end

  # === rental purchase_type validation ===

  test "rental purchase_type passes validation" do
    pe = purchase_events(:buy_event)
    pe.purchase_type = Grovs::Purchases::TYPE_RENTAL
    assert pe.valid?
  end

  test "rental purchase flows through pipeline as one-time" do
    pe = PurchaseEvent.create!(
      event_type: Grovs::Purchases::EVENT_BUY,
      project: projects(:one),
      price_cents: 299,
      currency: "USD",
      usd_price_cents: 299,
      date: Time.current,
      transaction_id: "txn_rental_test",
      product_id: "com.test.rental_movie",
      purchase_type: Grovs::Purchases::TYPE_RENTAL,
      store_source: Grovs::Webhooks::GOOGLE
    )

    assert pe.valid?
    assert pe.buy?
    assert_equal 299, pe.revenue_delta
  end
end
