require "test_helper"

class ProcessPurchaseEventJobTest < ActiveSupport::TestCase
  fixtures :instances, :projects, :devices, :visitors, :purchase_events,
           :in_app_products, :in_app_product_daily_statistics, :subscription_states

  setup do
    @job = ProcessPurchaseEventJob.new
    @project = projects(:one)
  end

  test "processes unprocessed buy event and marks as processed" do
    event = purchase_events(:unprocessed_buy)
    assert_not event.processed?

    @job.perform(event.id)

    event.reload
    assert event.processed?
  end

  test "skips already processed event" do
    event = purchase_events(:buy_event)
    assert event.processed?

    # Should not raise or change anything
    @job.perform(event.id)
  end

  test "skips nonexistent event" do
    assert_nothing_raised do
      @job.perform(999999)
    end
  end

  test "with PG shadow writes off the purchase still processes but writes no PG stats" do
    event = purchase_events(:unprocessed_buy)

    ch_rows = nil
    ENV["PG_SHADOW_WRITES"] = "false"
    begin
      ClickhouseWriteService.stub(:deliver_purchase_events, ->(rows) { ch_rows = rows }) do
        assert_no_difference ["DailyProjectMetric.count", "VisitorDailyStatistic.count",
                              "LinkDailyStatistic.count"] do
          @job.perform(event.id)
        end
      end
    ensure
      ENV.delete("PG_SHADOW_WRITES")
    end

    assert event.reload.processed?
    assert_not_nil event.revenue_platform, "the ledger snapshot is not a shadow write"
    assert_equal [event.transaction_id], ch_rows.to_a.map { |row| row[:transaction_id] },
                 "the ClickHouse purchase write stays unconditional"
  end

  test "processing persists ledger snapshots with store platform winning over device" do
    event = PurchaseEvent.create!(
      event_type: Grovs::Purchases::EVENT_BUY, device: devices(:ios_device), project: @project,
      usd_price_cents: 999, transaction_id: "txn_snap_store", product_id: "com.test.p",
      store_source: Grovs::Webhooks::GOOGLE, webhook_validated: true, store: true,
      purchase_type: Grovs::Purchases::TYPE_ONE_TIME
    )

    @job.perform(event.id)

    event.reload
    assert_equal Grovs::Platforms::ANDROID, event.revenue_platform, "store_source wins over device platform"
    assert_equal visitors(:ios_visitor).id, event.visitor_id
  end

  test "processing snapshots web platform and nil visitor for device-less webhook events" do
    event = PurchaseEvent.create!(
      event_type: Grovs::Purchases::EVENT_BUY, device: nil, project: @project,
      usd_price_cents: 500, transaction_id: "txn_snap_nodev", product_id: "com.test.p",
      webhook_validated: true, store: true, purchase_type: Grovs::Purchases::TYPE_ONE_TIME
    )

    @job.perform(event.id)

    event.reload
    assert_equal Grovs::Platforms::WEB, event.revenue_platform
    assert_nil event.visitor_id
  end

  test "price correction does not rewrite ledger snapshots" do
    event = PurchaseEvent.create!(
      event_type: Grovs::Purchases::EVENT_BUY, device: devices(:ios_device), project: @project,
      usd_price_cents: 999, transaction_id: "txn_snap_corr", product_id: "com.test.p",
      store_source: Grovs::Webhooks::GOOGLE, webhook_validated: true, store: true,
      purchase_type: Grovs::Purchases::TYPE_ONE_TIME
    )
    @job.perform(event.id)
    # Valid-but-different sentinel values (corrections consume the platform snapshot).
    event.update_columns(revenue_platform: Grovs::Platforms::IOS, visitor_id: 12_345, usd_price_cents: 1999)

    @job.perform(event.id, 999) # correction run

    event.reload
    assert_equal Grovs::Platforms::IOS, event.revenue_platform, "correction must not recompute the snapshot (android)"
    assert_equal 12_345, event.visitor_id
  end

  test "price correction lands under the snapshot platform even after the device changes" do
    event = PurchaseEvent.create!(
      event_type: Grovs::Purchases::EVENT_BUY, device: devices(:ios_device), project: @project,
      usd_price_cents: 999, transaction_id: "txn_corr_platform", product_id: "com.test.p",
      purchase_type: Grovs::Purchases::TYPE_ONE_TIME
    )
    @job.perform(event.id)
    assert_equal Grovs::Platforms::IOS, event.reload.revenue_platform

    devices(:ios_device).update_columns(platform: "web")
    event.update_columns(usd_price_cents: 1999)
    @job.perform(event.id, 999) # +1000 correction

    ios_metric = DailyProjectMetric.find_by(project_id: @project.id, platform: Grovs::Platforms::IOS,
                                            event_date: event.date.to_date)
    web_metric = DailyProjectMetric.find_by(project_id: @project.id, platform: Grovs::Platforms::WEB,
                                            event_date: event.date.to_date)
    assert_equal 1999, ios_metric.revenue, "full corrected value stays on the snapshot platform"
    assert_nil web_metric, "no split onto the device's new platform"
  end

  test "price correction credits the snapshot visitor, not a re-resolved one" do
    event = PurchaseEvent.create!(
      event_type: Grovs::Purchases::EVENT_BUY, device: devices(:ios_device), project: @project,
      usd_price_cents: 999, transaction_id: "txn_corr_visitor", product_id: "com.test.p",
      purchase_type: Grovs::Purchases::TYPE_ONE_TIME
    )
    @job.perform(event.id)
    # Simulate a visitor re-association since processing: snapshot points elsewhere.
    event.update_columns(visitor_id: visitors(:android_visitor).id, usd_price_cents: 1999)

    @job.perform(event.id, 999) # +1000 correction

    android_rev = VisitorDailyStatistic.where(project_id: @project.id, visitor_id: visitors(:android_visitor).id,
                                              event_date: event.date.to_date).sum(:revenue)
    ios_rev = VisitorDailyStatistic.where(project_id: @project.id, visitor_id: visitors(:ios_visitor).id,
                                          event_date: event.date.to_date).sum(:revenue)
    assert_equal 1000, android_rev, "correction follows the ledger snapshot"
    assert_equal 999, ios_rev, "original processing credit stays put"
  end

  test "creates subscription_state after processing" do
    event = PurchaseEvent.create!(
      event_type: Grovs::Purchases::EVENT_BUY,
      device: devices(:ios_device),
      project: @project,
      identifier: "com.test.app",
      price_cents: 999,
      currency: "USD",
      usd_price_cents: 999,
      date: Date.new(2026, 3, 5),
      transaction_id: "txn_sub_state_test",
      original_transaction_id: "orig_sub_state_test",
      product_id: "com.test.premium",
      webhook_validated: true,
      store: true,
      purchase_type: Grovs::Purchases::TYPE_SUBSCRIPTION
    )

    @job.perform(event.id)

    state = SubscriptionState.find_by(
      project: @project,
      original_transaction_id: "orig_sub_state_test"
    )
    assert state, "SubscriptionState should be created"
    assert_equal event.device_id, state.device_id
    assert_equal "com.test.premium", state.product_id
    assert_equal "txn_sub_state_test", state.latest_transaction_id
  end

  test "raises when currency conversion fails for nil usd_price_cents" do
    event = purchase_events(:nil_usd_buy)
    event.update_columns(usd_price_cents: nil)

    # Stub convert_price_to_usd to simulate persistent failure (returns nil, doesn't set usd_price_cents)
    conversion_stub = ->(_price, _currency) { nil }

    CurrencyConversionService.stub(:to_usd_cents, conversion_stub) do
      assert_raises(RuntimeError, /Currency conversion failed/) do
        @job.perform(event.id)
      end
    end
  end

  test "apply_correction adjusts revenue delta" do
    event = purchase_events(:buy_event)
    old_usd = 500
    platform = Grovs::Platforms::IOS
    event_date = event.date.to_date

    metric_before = DailyProjectMetric.find_or_create_by!(
      project_id: event.project_id, platform: platform, event_date: event_date
    )
    revenue_before = metric_before.revenue || 0

    # Event has usd_price_cents=999, old was 500
    # correction = revenue_delta(999) - revenue_delta(500) = 999 - 500 = 499
    @job.perform(event.id, old_usd)

    metric_after = DailyProjectMetric.find_by(
      project_id: event.project_id, platform: platform, event_date: event_date
    )
    assert_equal 499, metric_after.revenue - revenue_before,
      "Should increment revenue by correction (999 - 500 = 499)"
  end

  test "apply_correction skips when no difference" do
    event = purchase_events(:buy_event)
    platform = Grovs::Platforms::IOS
    event_date = event.date.to_date

    metric_before = DailyProjectMetric.find_or_create_by!(
      project_id: event.project_id, platform: platform, event_date: event_date
    )
    revenue_before = metric_before.revenue || 0

    # Same old price as current — correction is 0, no writes expected
    @job.perform(event.id, event.usd_price_cents)

    metric_after = DailyProjectMetric.find_by(
      project_id: event.project_id, platform: platform, event_date: event_date
    )
    assert_equal revenue_before, metric_after.revenue,
      "Revenue should not change when old and new usd_price_cents are equal"
  end

  test "rolls back on failure in process_event" do
    event = PurchaseEvent.create!(
      event_type: Grovs::Purchases::EVENT_BUY,
      device: devices(:ios_device),
      project: @project,
      identifier: "com.test.app",
      price_cents: 999,
      currency: "USD",
      usd_price_cents: 999,
      date: Date.new(2026, 3, 5),
      transaction_id: "txn_rollback_test",
      original_transaction_id: "orig_rollback_test",
      product_id: "com.test.premium",
      webhook_validated: true,
      store: true,
      purchase_type: Grovs::Purchases::TYPE_SUBSCRIPTION
    )

    # Stub DailyProjectMetric.increment! to raise
    DailyProjectMetric.stub(:increment!, ->(*_args, **_kwargs) { raise "DB error" }) do
      assert_raises(RuntimeError) { @job.perform(event.id) }
    end

    event.reload
    assert_not event.processed?, "Should rollback processed flag on failure"
  end

  # === determine_platform: platform flows correctly into stats ===

  test "determine_platform: store_source apple records stats as ios" do
    event = PurchaseEvent.create!(
      event_type: Grovs::Purchases::EVENT_BUY,
      device: devices(:web_device),  # device is web, but store_source should override
      project: @project,
      identifier: "com.test.app",
      price_cents: 999, currency: "USD", usd_price_cents: 999,
      date: Date.new(2026, 3, 10),
      transaction_id: "txn_plat_apple", original_transaction_id: "orig_plat_apple",
      product_id: "com.test.platform_test",
      webhook_validated: true, store: true,
      store_source: Grovs::Webhooks::APPLE,
      purchase_type: Grovs::Purchases::TYPE_SUBSCRIPTION
    )

    @job.perform(event.id)

    stat = InAppProductDailyStatistic.joins(:in_app_product).find_by(
      in_app_products: { project_id: @project.id, product_id: "com.test.platform_test" },
      event_date: Date.new(2026, 3, 10)
    )
    assert stat, "Should create daily stat"
    assert_equal "ios", stat.platform, "Apple store_source must produce ios platform stat"
  end

  test "determine_platform: store_source google records stats as android" do
    event = PurchaseEvent.create!(
      event_type: Grovs::Purchases::EVENT_BUY,
      device: devices(:web_device),  # device is web, but store_source should override
      project: @project,
      identifier: "com.test.app",
      price_cents: 499, currency: "USD", usd_price_cents: 499,
      date: Date.new(2026, 3, 10),
      transaction_id: "txn_plat_google", original_transaction_id: "orig_plat_google",
      product_id: "com.test.platform_test_g",
      webhook_validated: true, store: true,
      store_source: Grovs::Webhooks::GOOGLE,
      purchase_type: Grovs::Purchases::TYPE_ONE_TIME
    )

    @job.perform(event.id)

    stat = InAppProductDailyStatistic.joins(:in_app_product).find_by(
      in_app_products: { project_id: @project.id, product_id: "com.test.platform_test_g" },
      event_date: Date.new(2026, 3, 10)
    )
    assert stat, "Should create daily stat"
    assert_equal "android", stat.platform, "Google store_source must produce android platform stat"
  end

  test "determine_platform: ios device without store_source records stats as ios" do
    event = PurchaseEvent.create!(
      event_type: Grovs::Purchases::EVENT_BUY,
      device: devices(:ios_device),
      project: @project,
      identifier: "com.test.app",
      price_cents: 999, currency: "USD", usd_price_cents: 999,
      date: Date.new(2026, 3, 10),
      transaction_id: "txn_plat_iosdev", original_transaction_id: "orig_plat_iosdev",
      product_id: "com.test.platform_test_iosdev",
      webhook_validated: false, store: false,
      purchase_type: Grovs::Purchases::TYPE_ONE_TIME
    )

    @job.perform(event.id)

    stat = InAppProductDailyStatistic.joins(:in_app_product).find_by(
      in_app_products: { project_id: @project.id, product_id: "com.test.platform_test_iosdev" },
      event_date: Date.new(2026, 3, 10)
    )
    assert stat, "Should create daily stat"
    assert_equal "ios", stat.platform, "iOS device must produce ios platform stat when no store_source"
  end

  test "determine_platform: android device without store_source records stats as android" do
    event = PurchaseEvent.create!(
      event_type: Grovs::Purchases::EVENT_BUY,
      device: devices(:android_device),
      project: @project,
      identifier: "com.test.app",
      price_cents: 499, currency: "USD", usd_price_cents: 499,
      date: Date.new(2026, 3, 10),
      transaction_id: "txn_plat_anddev", original_transaction_id: "orig_plat_anddev",
      product_id: "com.test.platform_test_anddev",
      webhook_validated: false, store: false,
      purchase_type: Grovs::Purchases::TYPE_ONE_TIME
    )

    @job.perform(event.id)

    stat = InAppProductDailyStatistic.joins(:in_app_product).find_by(
      in_app_products: { project_id: @project.id, product_id: "com.test.platform_test_anddev" },
      event_date: Date.new(2026, 3, 10)
    )
    assert stat, "Should create daily stat"
    assert_equal "android", stat.platform, "Android device must produce android platform stat when no store_source"
  end

  test "determine_platform: web device records web while ios device records ios for same product" do
    # Process a web-device purchase and an ios-device purchase for the same product.
    # If determine_platform ignores device.platform_for_metrics (e.g. always returns "web"),
    # the ios assertion will fail.
    web_event = PurchaseEvent.create!(
      event_type: Grovs::Purchases::EVENT_BUY,
      device: devices(:web_device),
      project: @project,
      identifier: "com.test.webapp",
      price_cents: 299, currency: "USD", usd_price_cents: 299,
      date: Date.new(2026, 3, 10),
      transaction_id: "txn_plat_webdev", original_transaction_id: "orig_plat_webdev",
      product_id: "com.test.platform_contrast",
      webhook_validated: false, store: false,
      purchase_type: Grovs::Purchases::TYPE_ONE_TIME
    )
    ios_event = PurchaseEvent.create!(
      event_type: Grovs::Purchases::EVENT_BUY,
      device: devices(:ios_device),
      project: @project,
      identifier: "com.test.app",
      price_cents: 999, currency: "USD", usd_price_cents: 999,
      date: Date.new(2026, 3, 10),
      transaction_id: "txn_plat_webdev_ios", original_transaction_id: "orig_plat_webdev_ios",
      product_id: "com.test.platform_contrast",
      webhook_validated: false, store: false,
      purchase_type: Grovs::Purchases::TYPE_ONE_TIME
    )

    @job.perform(web_event.id)
    @job.perform(ios_event.id)

    stats = InAppProductDailyStatistic.joins(:in_app_product).where(
      in_app_products: { project_id: @project.id, product_id: "com.test.platform_contrast" },
      event_date: Date.new(2026, 3, 10)
    )
    web_stat = stats.find_by(platform: "web")
    ios_stat = stats.find_by(platform: "ios")
    assert web_stat, "Web device must produce a web platform stat"
    assert ios_stat, "iOS device must produce an ios platform stat (proves web result isn't just a default)"
  end

  test "determine_platform: no device records web while ios device records ios for same product" do
    # Process a no-device purchase and an ios-device purchase for the same product.
    # If determine_platform always returns "web", the ios assertion will fail.
    nodev_event = PurchaseEvent.create!(
      event_type: Grovs::Purchases::EVENT_BUY,
      project: @project,
      identifier: "com.test.app",
      price_cents: 999, currency: "USD", usd_price_cents: 999,
      date: Date.new(2026, 3, 10),
      transaction_id: "txn_plat_nodev", original_transaction_id: "orig_plat_nodev",
      product_id: "com.test.platform_nodev_contrast",
      webhook_validated: true, store: true,
      purchase_type: Grovs::Purchases::TYPE_SUBSCRIPTION
    )
    ios_event = PurchaseEvent.create!(
      event_type: Grovs::Purchases::EVENT_BUY,
      device: devices(:ios_device),
      project: @project,
      identifier: "com.test.app",
      price_cents: 999, currency: "USD", usd_price_cents: 999,
      date: Date.new(2026, 3, 10),
      transaction_id: "txn_plat_nodev_ios", original_transaction_id: "orig_plat_nodev_ios",
      product_id: "com.test.platform_nodev_contrast",
      webhook_validated: false, store: false,
      purchase_type: Grovs::Purchases::TYPE_ONE_TIME
    )

    @job.perform(nodev_event.id)
    @job.perform(ios_event.id)

    stats = InAppProductDailyStatistic.joins(:in_app_product).where(
      in_app_products: { project_id: @project.id, product_id: "com.test.platform_nodev_contrast" },
      event_date: Date.new(2026, 3, 10)
    )
    web_stat = stats.find_by(platform: "web")
    ios_stat = stats.find_by(platform: "ios")
    assert web_stat, "No-device event must default to web platform stat"
    assert ios_stat, "iOS device must produce ios stat (proves web result isn't just a hardcoded default)"
  end

  # === quantity-aware stats ===

  test "units_sold increments by quantity for buy event" do
    event = PurchaseEvent.create!(
      event_type: Grovs::Purchases::EVENT_BUY,
      device: devices(:android_device),
      project: @project,
      identifier: "com.test.app",
      price_cents: 100, currency: "USD", usd_price_cents: 100,
      date: Date.new(2026, 3, 15),
      transaction_id: "txn_qty_units", original_transaction_id: "orig_qty_units",
      product_id: "com.test.gems_qty",
      webhook_validated: true, store: true,
      store_source: Grovs::Webhooks::GOOGLE,
      purchase_type: Grovs::Purchases::TYPE_ONE_TIME,
      quantity: 3
    )

    @job.perform(event.id)

    metric = DailyProjectMetric.find_by(project_id: @project.id, event_date: Date.new(2026, 3, 15))
    assert metric
    assert_equal 3, metric.units_sold
  end

  test "cancellations increment by quantity for cancel one-time event" do
    # Need a processed buy event first for the metric to exist
    buy = PurchaseEvent.create!(
      event_type: Grovs::Purchases::EVENT_BUY,
      device: devices(:android_device),
      project: @project,
      identifier: "com.test.app",
      price_cents: 100, currency: "USD", usd_price_cents: 100,
      date: Date.new(2026, 3, 16),
      transaction_id: "txn_qty_cancel_buy", original_transaction_id: "orig_qty_cancel",
      product_id: "com.test.gems_cancel_qty",
      webhook_validated: true, store: true,
      store_source: Grovs::Webhooks::GOOGLE,
      purchase_type: Grovs::Purchases::TYPE_ONE_TIME,
      quantity: 4
    )
    @job.perform(buy.id)

    cancel = PurchaseEvent.create!(
      event_type: Grovs::Purchases::EVENT_CANCEL,
      device: devices(:android_device),
      project: @project,
      identifier: "com.test.app",
      price_cents: 100, currency: "USD", usd_price_cents: 100,
      date: Date.new(2026, 3, 16),
      transaction_id: "txn_qty_cancel", original_transaction_id: "orig_qty_cancel",
      product_id: "com.test.gems_cancel_qty",
      webhook_validated: true, store: true,
      store_source: Grovs::Webhooks::GOOGLE,
      purchase_type: Grovs::Purchases::TYPE_ONE_TIME,
      quantity: 2
    )

    @job.perform(cancel.id)

    metric = DailyProjectMetric.find_by(project_id: @project.id, event_date: Date.new(2026, 3, 16))
    assert metric
    assert_equal 2, metric.cancellations
  end

  test "revenue uses quantity * price for buy event" do
    event = PurchaseEvent.create!(
      event_type: Grovs::Purchases::EVENT_BUY,
      device: devices(:android_device),
      project: @project,
      identifier: "com.test.app",
      price_cents: 500, currency: "USD", usd_price_cents: 500,
      date: Date.new(2026, 3, 17),
      transaction_id: "txn_qty_revenue", original_transaction_id: "orig_qty_revenue",
      product_id: "com.test.gems_revenue_qty",
      webhook_validated: true, store: true,
      store_source: Grovs::Webhooks::GOOGLE,
      purchase_type: Grovs::Purchases::TYPE_ONE_TIME,
      quantity: 3
    )

    @job.perform(event.id)

    metric = DailyProjectMetric.find_by(project_id: @project.id, event_date: Date.new(2026, 3, 17))
    assert metric
    assert_equal 1500, metric.revenue, "Revenue should be 500 * 3 = 1500"
  end

  test "InAppProductDailyStatistic counts by quantity" do
    event = PurchaseEvent.create!(
      event_type: Grovs::Purchases::EVENT_BUY,
      device: devices(:android_device),
      project: @project,
      identifier: "com.test.app",
      price_cents: 200, currency: "USD", usd_price_cents: 200,
      date: Date.new(2026, 3, 18),
      transaction_id: "txn_qty_iap_stat", original_transaction_id: "orig_qty_iap_stat",
      product_id: "com.test.gems_stat_qty",
      webhook_validated: true, store: true,
      store_source: Grovs::Webhooks::GOOGLE,
      purchase_type: Grovs::Purchases::TYPE_ONE_TIME,
      quantity: 4
    )

    @job.perform(event.id)

    stat = InAppProductDailyStatistic.joins(:in_app_product).find_by(
      in_app_products: { project_id: @project.id, product_id: "com.test.gems_stat_qty" },
      event_date: Date.new(2026, 3, 18)
    )
    assert stat, "Should create daily stat"
    assert_equal 4, stat.purchase_events, "purchase_events should equal quantity"
  end

  test "determine_platform: store_source overrides device platform" do
    # Apple webhook for a purchase originally made via web device
    # store_source=apple should override web device → stats recorded as ios
    event = PurchaseEvent.create!(
      event_type: Grovs::Purchases::EVENT_BUY,
      device: devices(:web_device),
      project: @project,
      identifier: "com.test.app",
      price_cents: 999, currency: "USD", usd_price_cents: 999,
      date: Date.new(2026, 3, 10),
      transaction_id: "txn_plat_override", original_transaction_id: "orig_plat_override",
      product_id: "com.test.platform_override",
      webhook_validated: true, store: true,
      store_source: Grovs::Webhooks::APPLE,
      purchase_type: Grovs::Purchases::TYPE_SUBSCRIPTION
    )

    @job.perform(event.id)

    stat = InAppProductDailyStatistic.joins(:in_app_product).find_by(
      in_app_products: { project_id: @project.id, product_id: "com.test.platform_override" },
      event_date: Date.new(2026, 3, 10)
    )
    assert_equal "ios", stat.platform, "store_source=apple must override web device to ios"

    # Verify no web stat was created for this product
    web_stat = InAppProductDailyStatistic.joins(:in_app_product).find_by(
      in_app_products: { project_id: @project.id, product_id: "com.test.platform_override" },
      platform: "web"
    )
    assert_nil web_stat, "No web platform stat should exist when store_source overrides to ios"
  end

  test "subscription_state upsert preserves device_id when renewal has nil device" do
    # First, process an event with a device to create the subscription_state
    event1 = PurchaseEvent.create!(
      event_type: Grovs::Purchases::EVENT_BUY,
      device: devices(:ios_device),
      project: @project,
      identifier: "com.test.app",
      price_cents: 999,
      currency: "USD",
      usd_price_cents: 999,
      date: Date.new(2026, 3, 5),
      transaction_id: "txn_coalesce_001",
      original_transaction_id: "orig_coalesce_001",
      product_id: "com.test.premium",
      webhook_validated: true,
      store: true,
      purchase_type: Grovs::Purchases::TYPE_SUBSCRIPTION
    )

    @job.perform(event1.id)

    state = SubscriptionState.find_by(
      project: @project,
      original_transaction_id: "orig_coalesce_001"
    )
    assert state
    assert_equal devices(:ios_device).id, state.device_id

    # Now process a renewal without a device (webhook-only)
    event2 = PurchaseEvent.create!(
      event_type: Grovs::Purchases::EVENT_BUY,
      project: @project,
      identifier: "com.test.app",
      price_cents: 999,
      currency: "USD",
      usd_price_cents: 999,
      date: Date.new(2026, 3, 6),
      transaction_id: "txn_coalesce_002",
      original_transaction_id: "orig_coalesce_001",
      product_id: "com.test.premium",
      webhook_validated: true,
      store: true,
      store_source: Grovs::Webhooks::APPLE,
      purchase_type: Grovs::Purchases::TYPE_SUBSCRIPTION
    )

    @job.perform(event2.id)

    state.reload
    assert_equal devices(:ios_device).id, state.device_id, "device_id should be preserved from original purchase"
    assert_equal "txn_coalesce_002", state.latest_transaction_id, "latest_transaction_id should be updated"
  end
end
