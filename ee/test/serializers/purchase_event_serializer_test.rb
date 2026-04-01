require "test_helper"

class PurchaseEventSerializerTest < ActiveSupport::TestCase
  fixtures :purchase_events, :projects, :devices, :instances

  # ---------------------------------------------------------------------------
  # 1. VALUE VERIFICATION
  # ---------------------------------------------------------------------------

  test "serializes all declared attributes with correct values for buy_event" do
    pe = purchase_events(:buy_event)
    result = PurchaseEventSerializer.serialize(pe)

    assert_equal pe.id, result["id"]
    assert_equal "buy", result["event_type"]
    assert_equal "subscription", result["purchase_type"]
    assert_equal "com.test.premium", result["product_id"]
    assert_equal "com.test.app", result["identifier"]
    assert_equal "txn_buy_001", result["transaction_id"]
    assert_equal "orig_txn_001", result["original_transaction_id"]
    assert_equal 999, result["price_cents"]
    assert_equal 999, result["usd_price_cents"]
    assert_equal "USD", result["currency"]
    assert_equal Time.utc(2026, 3, 1, 10, 0, 0), result["date"]
    assert_equal Time.utc(2027, 3, 1, 10, 0, 0), result["expires_date"]
    assert_equal true, result["processed"]
    assert_equal true, result["store"]
    assert_equal "apple", result["store_source"]
    assert_equal true, result["webhook_validated"]
  end

  test "serializes computed platform field from device association" do
    pe = purchase_events(:buy_event)
    result = PurchaseEventSerializer.serialize(pe)

    assert_equal "ios", result["platform"]
  end

  test "serializes computed link_id field" do
    pe = purchase_events(:buy_event)
    result = PurchaseEventSerializer.serialize(pe)

    # Fixture does not set a link association
    assert_nil result["link_id"]
  end

  test "serializes buy_one_time with android platform" do
    pe = purchase_events(:buy_one_time)
    result = PurchaseEventSerializer.serialize(pe)

    assert_equal pe.id, result["id"]
    assert_equal "android", result["platform"]
    assert_equal "one_time", result["purchase_type"]
    assert_equal "buy", result["event_type"]
    assert_equal 499, result["price_cents"]
    assert_equal 499, result["usd_price_cents"]
    assert_equal "USD", result["currency"]
    assert_equal "txn_buy_ot_001", result["transaction_id"]
    assert_equal "orig_txn_002", result["original_transaction_id"]
    assert_equal "com.test.onetime", result["product_id"]
    # Fixture does not set a link association
    assert_nil result["link_id"]
  end

  test "serializes cancel event with correct values" do
    pe = purchase_events(:cancel_event)
    result = PurchaseEventSerializer.serialize(pe)

    assert_equal pe.id, result["id"]
    assert_equal "cancel", result["event_type"]
    assert_equal "subscription", result["purchase_type"]
    assert_equal "txn_cancel_001", result["transaction_id"]
    assert_equal 999, result["price_cents"]
    assert_equal "ios", result["platform"]
  end

  test "serializes refund event with correct values" do
    pe = purchase_events(:refund_event)
    result = PurchaseEventSerializer.serialize(pe)

    assert_equal pe.id, result["id"]
    assert_equal "refund", result["event_type"]
    assert_equal "one_time", result["purchase_type"]
    assert_equal 499, result["price_cents"]
    assert_equal "txn_refund_001", result["transaction_id"]
  end

  test "serializes unprocessed buy with processed false" do
    pe = purchase_events(:unprocessed_buy)
    result = PurchaseEventSerializer.serialize(pe)

    assert_equal pe.id, result["id"]
    assert_equal false, result["processed"]
    assert_equal 1999, result["price_cents"]
    assert_equal "subscription", result["purchase_type"]
  end

  # ---------------------------------------------------------------------------
  # 2. EXCLUSION
  # ---------------------------------------------------------------------------

  test "excludes device_id project_id created_at and updated_at" do
    result = PurchaseEventSerializer.serialize(purchase_events(:buy_event))

    %w[device_id project_id created_at updated_at].each do |field|
      assert_not_includes result.keys, field
    end
  end

  # ---------------------------------------------------------------------------
  # 3. NIL HANDLING
  # ---------------------------------------------------------------------------

  test "returns nil for nil input" do
    assert_nil PurchaseEventSerializer.serialize(nil)
  end

  # ---------------------------------------------------------------------------
  # 4. COLLECTION HANDLING
  # ---------------------------------------------------------------------------

  test "serializes a collection with correct size and distinct transaction_ids" do
    events = [purchase_events(:buy_event), purchase_events(:buy_one_time), purchase_events(:cancel_event)]
    results = PurchaseEventSerializer.serialize(events)

    assert_equal 3, results.size
    assert_equal "txn_buy_001", results[0]["transaction_id"]
    assert_equal "txn_buy_ot_001", results[1]["transaction_id"]
    assert_equal "txn_cancel_001", results[2]["transaction_id"]
  end

  # ---------------------------------------------------------------------------
  # 5. EDGE CASES -- computed field variations
  # ---------------------------------------------------------------------------

  test "platform falls back to nil when device is nil and store_source is nil" do
    pe = purchase_events(:no_device_buy)
    result = PurchaseEventSerializer.serialize(pe)

    assert_nil pe.device
    assert_nil pe.store_source
    assert_nil result["platform"]
  end

  test "platform uses store_platform when device is nil but store_source is set" do
    pe = purchase_events(:no_device_buy)
    pe.store_source = "apple"
    result = PurchaseEventSerializer.serialize(pe)

    assert_equal "ios", result["platform"]
  end

  test "platform prefers device platform over store_platform" do
    pe = purchase_events(:buy_event)
    pe.store_source = "google"
    result = PurchaseEventSerializer.serialize(pe)

    # Device is ios_device with platform "ios", which takes precedence
    assert_equal "ios", result["platform"]
  end
end
