require "test_helper"

class InAppProductEventServiceTest < ActiveSupport::TestCase
  fixtures :instances, :projects, :devices, :visitors, :purchase_events, :in_app_products,
           :in_app_product_daily_statistics

  setup do
    @project = projects(:one)
    @ios_device = devices(:ios_device)
    @android_device = devices(:android_device)
  end

  test "record_purchase creates InAppProduct and daily stats for buy event" do
    event = PurchaseEvent.create!(
      event_type: Grovs::Purchases::EVENT_BUY,
      device: @ios_device,
      project: @project,
      identifier: "com.test.app",
      price_cents: 1299,
      currency: "USD",
      usd_price_cents: 1299,
      date: Date.new(2026, 3, 5),
      transaction_id: "txn_new_buy_001",
      original_transaction_id: "orig_new_001",
      product_id: "com.test.newproduct",
      webhook_validated: true,
      store: true,
      purchase_type: Grovs::Purchases::TYPE_SUBSCRIPTION
    )

    InAppProductEventService.record_purchase(event, platform: Grovs::Platforms::IOS, event_date: Date.new(2026, 3, 5))

    product = InAppProduct.find_by(project: @project, product_id: "com.test.newproduct", platform: Grovs::Platforms::IOS)
    assert product, "InAppProduct should be created"

    stats = InAppProductDailyStatistic.find_by(
      in_app_product: product,
      event_date: Date.new(2026, 3, 5),
      platform: Grovs::Platforms::IOS
    )
    assert stats, "Daily stats should be created"
    assert_equal 1299, stats.revenue
    assert_equal 1, stats.purchase_events
    assert_equal 0, stats.canceled_events
    assert_equal 1, stats.first_time_purchases
    assert_equal 0, stats.repeat_purchases
    assert_equal 1299, stats.device_revenue
  end

  test "record_purchase tracks repeat_purchases for non-first-time buy" do
    first_event = purchase_events(:buy_event)

    # Seed device_product_purchases so the first buy is already recorded
    DeviceProductPurchase.create!(
      device: @ios_device,
      project: @project,
      product_id: "com.test.premium"
    )

    repeat_event = PurchaseEvent.create!(
      event_type: Grovs::Purchases::EVENT_BUY,
      device: @ios_device,
      project: @project,
      identifier: "com.test.app",
      price_cents: 999,
      currency: "USD",
      usd_price_cents: 999,
      date: Date.new(2026, 3, 10),
      transaction_id: "txn_repeat_test",
      original_transaction_id: "orig_txn_001",
      product_id: "com.test.premium",
      webhook_validated: true,
      store: true,
      purchase_type: Grovs::Purchases::TYPE_SUBSCRIPTION
    )

    InAppProductEventService.record_purchase(repeat_event, platform: Grovs::Platforms::IOS, event_date: Date.new(2026, 3, 10))

    stats = InAppProductDailyStatistic.find_by(
      in_app_product: in_app_products(:premium_ios),
      event_date: Date.new(2026, 3, 10),
      platform: Grovs::Platforms::IOS
    )
    assert_equal 1, stats.repeat_purchases
    assert_equal 0, stats.first_time_purchases
  end

  test "record_purchase increments unique_purchasing_devices on first-time purchase" do
    product = in_app_products(:premium_ios)
    original_count = product.unique_purchasing_devices

    event = PurchaseEvent.create!(
      event_type: Grovs::Purchases::EVENT_BUY,
      device: @android_device,
      project: @project,
      identifier: "com.test.app",
      price_cents: 999,
      currency: "USD",
      usd_price_cents: 999,
      date: Date.new(2026, 3, 10),
      transaction_id: "txn_first_device",
      original_transaction_id: "orig_new_device",
      product_id: "com.test.premium",
      webhook_validated: true,
      store: true,
      purchase_type: Grovs::Purchases::TYPE_SUBSCRIPTION
    )

    InAppProductEventService.record_purchase(event, platform: Grovs::Platforms::IOS, event_date: Date.new(2026, 3, 10))

    product.reload
    assert_equal original_count + 1, product.unique_purchasing_devices
  end

  test "record_purchase sets device_revenue to 0 when no device_id" do
    event = PurchaseEvent.create!(
      event_type: Grovs::Purchases::EVENT_BUY,
      project: @project,
      identifier: "com.test.app",
      price_cents: 999,
      currency: "USD",
      usd_price_cents: 999,
      date: Date.new(2026, 3, 10),
      transaction_id: "txn_nodev_test",
      original_transaction_id: "orig_nodev_test",
      product_id: "com.test.newprod2",
      webhook_validated: true,
      store: true,
      purchase_type: Grovs::Purchases::TYPE_SUBSCRIPTION
    )

    InAppProductEventService.record_purchase(event, platform: Grovs::Platforms::WEB, event_date: Date.new(2026, 3, 10))

    product = InAppProduct.find_by(project: @project, product_id: "com.test.newprod2")
    stats = InAppProductDailyStatistic.find_by(in_app_product: product, event_date: Date.new(2026, 3, 10))
    assert_equal 0, stats.device_revenue
    assert_equal 999, stats.revenue
  end

  test "record_purchase handles cancel event correctly" do
    event = PurchaseEvent.create!(
      event_type: Grovs::Purchases::EVENT_CANCEL,
      device: @ios_device,
      project: @project,
      identifier: "com.test.app",
      price_cents: 999,
      currency: "USD",
      usd_price_cents: 999,
      date: Date.new(2026, 3, 10),
      transaction_id: "txn_cancel_test",
      original_transaction_id: "orig_cancel_test",
      product_id: "com.test.premium",
      webhook_validated: true,
      store: true,
      purchase_type: Grovs::Purchases::TYPE_SUBSCRIPTION
    )

    InAppProductEventService.record_purchase(event, platform: Grovs::Platforms::IOS, event_date: Date.new(2026, 3, 10))

    stats = InAppProductDailyStatistic.find_by(
      in_app_product: in_app_products(:premium_ios),
      event_date: Date.new(2026, 3, 10),
      platform: Grovs::Platforms::IOS
    )
    assert_equal 0, stats.purchase_events
    assert_equal 1, stats.canceled_events
  end

  test "apply_revenue_correction adjusts revenue and device_revenue" do
    event = purchase_events(:buy_event)

    InAppProductEventService.apply_revenue_correction(
      event,
      platform: Grovs::Platforms::IOS,
      event_date: Date.new(2026, 3, 1),
      correction: 500
    )

    stats = in_app_product_daily_statistics(:premium_day1)
    stats.reload
    assert_equal 999 + 500, stats.revenue
    assert_equal 999 + 500, stats.device_revenue
  end

  test "apply_revenue_correction sets device_revenue to 0 for no-device event" do
    event = purchase_events(:no_device_buy)

    InAppProductEventService.apply_revenue_correction(
      event,
      platform: Grovs::Platforms::WEB,
      event_date: Date.new(2026, 3, 1),
      correction: 200
    )

    product = InAppProduct.find_by(project: @project, product_id: "com.test.premium", platform: Grovs::Platforms::WEB)
    stats = InAppProductDailyStatistic.find_by(in_app_product: product, event_date: Date.new(2026, 3, 1))
    assert_equal 200, stats.revenue
    assert_equal 0, stats.device_revenue
  end

  test "record_purchase skips when product_id blank" do
    event = PurchaseEvent.new(
      event_type: Grovs::Purchases::EVENT_BUY,
      project: @project,
      product_id: nil
    )

    assert_no_difference "InAppProductDailyStatistic.count" do
      InAppProductEventService.record_purchase(event)
    end
  end

  # --- record_device_attribution tests ---

  test "record_device_attribution creates first-time purchase stats" do
    event = PurchaseEvent.create!(
      event_type: Grovs::Purchases::EVENT_BUY,
      device: @android_device,
      project: @project,
      identifier: "com.test.app",
      price_cents: 799,
      currency: "USD",
      usd_price_cents: 799,
      date: Date.new(2026, 3, 15),
      transaction_id: "txn_attr_first",
      original_transaction_id: "orig_attr_first",
      product_id: "com.test.premium",
      webhook_validated: true,
      store: true,
      purchase_type: Grovs::Purchases::TYPE_SUBSCRIPTION
    )

    product = in_app_products(:premium_ios)
    original_devices = product.unique_purchasing_devices

    InAppProductEventService.record_device_attribution(event, platform: Grovs::Platforms::IOS, event_date: Date.new(2026, 3, 15))

    product.reload
    assert_equal original_devices + 1, product.unique_purchasing_devices

    stats = InAppProductDailyStatistic.find_by(
      in_app_product: product, event_date: Date.new(2026, 3, 15), platform: Grovs::Platforms::IOS
    )
    assert_equal 1, stats.first_time_purchases
    assert_equal 799, stats.device_revenue
    assert_equal 0, stats.revenue # record_device_attribution sets revenue to 0
  end

  test "record_device_attribution marks repeat for existing device" do
    # Seed: device already purchased this product
    DeviceProductPurchase.create!(device: @ios_device, project: @project, product_id: "com.test.premium")

    event = PurchaseEvent.create!(
      event_type: Grovs::Purchases::EVENT_BUY,
      device: @ios_device,
      project: @project,
      identifier: "com.test.app",
      price_cents: 999,
      currency: "USD",
      usd_price_cents: 999,
      date: Date.new(2026, 3, 15),
      transaction_id: "txn_attr_repeat",
      original_transaction_id: "orig_attr_repeat",
      product_id: "com.test.premium",
      webhook_validated: true,
      store: true,
      purchase_type: Grovs::Purchases::TYPE_SUBSCRIPTION
    )

    InAppProductEventService.record_device_attribution(event, platform: Grovs::Platforms::IOS, event_date: Date.new(2026, 3, 15))

    stats = InAppProductDailyStatistic.find_by(
      in_app_product: in_app_products(:premium_ios),
      event_date: Date.new(2026, 3, 15), platform: Grovs::Platforms::IOS
    )
    assert_equal 1, stats.repeat_purchases
    assert_equal 0, stats.first_time_purchases
  end

  test "record_device_attribution skips when no device_id" do
    event = PurchaseEvent.new(
      event_type: Grovs::Purchases::EVENT_BUY,
      project: @project,
      product_id: "com.test.premium"
    )

    assert_no_difference "InAppProductDailyStatistic.count" do
      InAppProductEventService.record_device_attribution(event, platform: Grovs::Platforms::IOS, event_date: Date.current)
    end
  end

  test "upsert_stats_correction decrements old platform counts" do
    # premium_day1 has purchase_events=1 on ios
    event = purchase_events(:buy_event)

    InAppProductEventService.upsert_stats_correction(
      event,
      platform: Grovs::Platforms::IOS,
      event_date: Date.new(2026, 3, 1),
      purchase_events: -1,
      canceled_events: 0
    )

    stats = in_app_product_daily_statistics(:premium_day1)
    stats.reload
    assert_equal 0, stats.purchase_events
  end

  test "upsert_stats_correction skips when product not found" do
    event = PurchaseEvent.new(
      event_type: Grovs::Purchases::EVENT_BUY,
      project: @project,
      product_id: "com.nonexistent.product"
    )

    assert_nothing_raised do
      InAppProductEventService.upsert_stats_correction(
        event, platform: Grovs::Platforms::IOS, event_date: Date.current,
        purchase_events: -1, canceled_events: 0
      )
    end
  end

  test "find_or_create_product handles race condition" do
    # First call creates the product
    product1 = InAppProductEventService.send(:find_or_create_product, @project.id, "com.race.test", Grovs::Platforms::IOS)
    assert product1

    # Simulate a second call finding the same product (RecordNotUnique → find_by!)
    InAppProduct.stub(:find_or_create_by!, ->(*_args) { raise ActiveRecord::RecordNotUnique }) do
      product2 = InAppProductEventService.send(:find_or_create_product, @project.id, "com.race.test", Grovs::Platforms::IOS)
      assert_equal product1.id, product2.id
    end
  end

  test "upsert_stats accumulates on conflict" do
    product = in_app_products(:premium_ios)
    stats_before = in_app_product_daily_statistics(:premium_day1)

    event = PurchaseEvent.create!(
      event_type: Grovs::Purchases::EVENT_BUY,
      device: @ios_device,
      project: @project,
      identifier: "com.test.app",
      price_cents: 500,
      currency: "USD",
      usd_price_cents: 500,
      date: Date.new(2026, 3, 1),
      transaction_id: "txn_upsert_test",
      original_transaction_id: "orig_upsert_test",
      product_id: "com.test.premium",
      webhook_validated: true,
      store: true,
      purchase_type: Grovs::Purchases::TYPE_SUBSCRIPTION
    )

    InAppProductEventService.record_purchase(event, platform: Grovs::Platforms::IOS, event_date: Date.new(2026, 3, 1))

    stats_before.reload
    assert_equal 999 + 500, stats_before.revenue
    assert_equal 2, stats_before.purchase_events
  end
end
