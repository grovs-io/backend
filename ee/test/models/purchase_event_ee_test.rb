require "test_helper"

# Tests for PurchaseEvent behavior that depends on Enterprise Edition services
# (CurrencyConversionService, PurchaseEventSerializer).
class PurchaseEventEeTest < ActiveSupport::TestCase
  fixtures :purchase_events, :projects, :devices, :instances

  # === assign_unique_transaction_id (requires CurrencyConversionService stub) ===

  test "assign_unique_transaction_id sets uuid when transaction_id is nil" do
    pe = PurchaseEvent.new(
      event_type: Grovs::Purchases::EVENT_BUY,
      project: projects(:one),
      price_cents: 100,
      currency: "USD",
      usd_price_cents: 100,
      date: Time.current
    )
    pe.transaction_id = nil
    CurrencyConversionService.stub(:to_usd_cents, 100) do
      pe.save!
    end
    assert_not_nil pe.transaction_id
    # Should look like a UUID
    assert_match(/\A[0-9a-f-]{36}\z/, pe.transaction_id)
  end

  # === serialization ===

  test "serializer excludes device_id project_id timestamps" do
    pe = purchase_events(:buy_event)
    json = PurchaseEventSerializer.serialize(pe)
    assert_nil json["device_id"]
    assert_nil json["project_id"]
    assert_nil json["created_at"]
    assert_nil json["updated_at"]
  end

  test "serializer includes platform from device" do
    pe = purchase_events(:buy_event)
    json = PurchaseEventSerializer.serialize(pe)
    assert_equal Grovs::Platforms::IOS, json["platform"]
  end

  test "serializer uses store_platform when device is nil" do
    pe = purchase_events(:no_device_buy)
    pe.store_source = Grovs::Webhooks::APPLE
    json = PurchaseEventSerializer.serialize(pe)
    assert_equal Grovs::Platforms::IOS, json["platform"]
  end

  # === convert_price_to_usd callback (MONEY PATH) ===

  test "convert_price_to_usd sets usd_price_cents for non-USD currency" do
    pe = PurchaseEvent.new(
      event_type: Grovs::Purchases::EVENT_BUY,
      project: projects(:one),
      price_cents: 1000,
      currency: "EUR",
      date: Time.current,
      transaction_id: "txn_eur_conv"
    )

    CurrencyConversionService.stub(:to_usd_cents, 1100) do
      pe.save!
    end
    assert_equal 1100, pe.usd_price_cents
  end

  test "convert_price_to_usd leaves usd_price_cents nil when conversion fails" do
    pe = PurchaseEvent.new(
      event_type: Grovs::Purchases::EVENT_BUY,
      project: projects(:one),
      price_cents: 1000,
      currency: "XYZ",
      date: Time.current,
      transaction_id: "txn_fail_conv"
    )

    CurrencyConversionService.stub(:to_usd_cents, nil) do
      pe.save!
    end
    assert_nil pe.usd_price_cents
  end

  test "convert_price_to_usd re-converts when price_cents changes" do
    pe = PurchaseEvent.create!(
      event_type: Grovs::Purchases::EVENT_BUY,
      project: projects(:one),
      price_cents: 500,
      currency: "EUR",
      usd_price_cents: 550,
      date: Time.current,
      transaction_id: "txn_reconvert_price"
    )

    CurrencyConversionService.stub(:to_usd_cents, 660) do
      pe.update!(price_cents: 600)
    end
    assert_equal 660, pe.usd_price_cents
  end

  test "convert_price_to_usd re-converts when currency changes" do
    pe = PurchaseEvent.create!(
      event_type: Grovs::Purchases::EVENT_BUY,
      project: projects(:one),
      price_cents: 500,
      currency: "EUR",
      usd_price_cents: 550,
      date: Time.current,
      transaction_id: "txn_reconvert_curr"
    )

    CurrencyConversionService.stub(:to_usd_cents, 700) do
      pe.update!(currency: "GBP")
    end
    assert_equal 700, pe.usd_price_cents
  end
end
