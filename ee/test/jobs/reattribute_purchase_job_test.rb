require "test_helper"

class ReattributePurchaseJobTest < ActiveSupport::TestCase
  fixtures :instances, :projects, :devices, :visitors, :purchase_events, :links, :domains, :redirect_configs,
           :stripe_subscriptions, :stripe_payment_intents

  setup do
    @job = ReattributePurchaseJob.new
    @project = projects(:one)
    @ios_device = devices(:ios_device)
    @link = links(:basic_link)
  end

  test "increments new platform and decrements old platform metrics when platform changes" do
    event = create_purchase_event(
      device: @ios_device,
      store_source: Grovs::Webhooks::GOOGLE, # store_platform => android, device => ios
      usd_price_cents: 999,
      event_type: Grovs::Purchases::EVENT_BUY
    )

    @job.perform(event.id)

    new_metric = DailyProjectMetric.find_by(project_id: @project.id, platform: Grovs::Platforms::IOS, event_date: Date.current)
    assert_not_nil new_metric
    assert_equal 999, new_metric.revenue
    assert_equal 1, new_metric.units_sold
    assert_equal 0, new_metric.cancellations

    old_metric = DailyProjectMetric.find_by(project_id: @project.id, platform: Grovs::Platforms::ANDROID, event_date: Date.current)
    assert_not_nil old_metric
    assert_equal(-999, old_metric.revenue)
    assert_equal(-1, old_metric.units_sold)
  end

  test "a redelivered run does not re-apply the revenue move" do
    event = create_purchase_event(
      device: @ios_device,
      store_source: Grovs::Webhooks::GOOGLE, # store=android, device=ios → cross-platform
      usd_price_cents: 999,
      event_type: Grovs::Purchases::EVENT_BUY
    )

    @job.perform(event.id)
    @job.perform(event.id) # Sidekiq redelivery after commit-before-ack

    new_metric = DailyProjectMetric.find_by(project_id: @project.id, platform: Grovs::Platforms::IOS, event_date: Date.current)
    old_metric = DailyProjectMetric.find_by(project_id: @project.id, platform: Grovs::Platforms::ANDROID, event_date: Date.current)
    assert_equal 999, new_metric.revenue, "revenue must be applied exactly once"
    assert_equal(-999, old_metric.revenue)
    assert_equal 1, new_metric.units_sold
  end

  test "with PG shadow writes off the reattribution still moves the ledger but writes no PG stats" do
    visitor = visitors(:ios_visitor)
    event = create_purchase_event(
      device: @ios_device,
      link: @link,
      store_source: Grovs::Webhooks::GOOGLE,
      usd_price_cents: 999,
      event_type: Grovs::Purchases::EVENT_BUY
    )
    # Reattribution MOVES money between existing rows, so counts alone would miss a leaked write.
    DailyProjectMetric.create!(project_id: @project.id, platform: Grovs::Platforms::IOS,
                              event_date: Date.current, revenue: 500, units_sold: 1)
    VisitorDailyStatistic.create!(project_id: @project.id, visitor_id: visitor.id,
                                  event_date: Date.current, platform: Grovs::Platforms::IOS, revenue: 500)
    LinkDailyStatistic.create!(project_id: @project.id, link_id: @link.id,
                               event_date: Date.current, platform: Grovs::Platforms::IOS, revenue: 500)
    before = pg_stat_snapshot

    ENV["PG_SHADOW_WRITES"] = "false"
    begin
      assert_no_difference ["DailyProjectMetric.count", "VisitorDailyStatistic.count",
                            "LinkDailyStatistic.count"] do
        @job.perform(event.id)
      end
    ensure
      ENV.delete("PG_SHADOW_WRITES")
    end

    assert_equal before, pg_stat_snapshot
    assert_equal Grovs::Platforms::IOS, event.reload.revenue_platform
    assert_equal visitor.id, event.visitor_id
    assert InAppProductDailyStatistic.where(project_id: @project.id).exists?,
           "product stats stay ungated — revenue reporting still reads them"
  end

  def pg_stat_snapshot
    [DailyProjectMetric.where(project_id: @project.id).order(:id).pluck(:platform, :revenue, :units_sold, :cancellations),
     VisitorDailyStatistic.where(project_id: @project.id).order(:id).pluck(:visitor_id, :platform, :revenue),
     LinkDailyStatistic.where(project_id: @project.id).order(:id).pluck(:link_id, :platform, :revenue)]
  end

  test "handles cancellation metrics correctly on platform change" do
    event = create_purchase_event(
      device: @ios_device,
      store_source: Grovs::Webhooks::GOOGLE,
      usd_price_cents: 0,
      event_type: Grovs::Purchases::EVENT_CANCEL
    )

    @job.perform(event.id)

    new_metric = DailyProjectMetric.find_by(project_id: @project.id, platform: Grovs::Platforms::IOS, event_date: Date.current)
    assert_equal 1, new_metric.cancellations

    old_metric = DailyProjectMetric.find_by(project_id: @project.id, platform: Grovs::Platforms::ANDROID, event_date: Date.current)
    assert_equal(-1, old_metric.cancellations)
  end

  # --- Visitor revenue attribution ---

  test "increments visitor daily stat revenue when revenue is nonzero" do
    visitor = visitors(:ios_visitor)
    event = create_purchase_event(
      device: @ios_device,
      store_source: Grovs::Webhooks::APPLE, # same platform, no metric move
      usd_price_cents: 500,
      event_type: Grovs::Purchases::EVENT_BUY
    )

    @job.perform(event.id)

    vds = VisitorDailyStatistic.find_by(visitor_id: visitor.id, event_date: Date.current, platform: Grovs::Platforms::IOS)
    assert_not_nil vds, "Should create VisitorDailyStatistic"
    assert_equal 500, vds.revenue
  end

  test "moves link daily stat revenue to the device platform when it changes" do
    # Store apple (ios) processed device-less → device turns out to be android.
    event = create_purchase_event(
      device: devices(:android_device),
      link: @link,
      store_source: Grovs::Webhooks::APPLE,
      usd_price_cents: 700,
      event_type: Grovs::Purchases::EVENT_BUY
    )

    @job.perform(event.id)

    android = LinkDailyStatistic.find_by(link_id: @link.id, event_date: Date.current, platform: Grovs::Platforms::ANDROID)
    ios = LinkDailyStatistic.find_by(link_id: @link.id, event_date: Date.current, platform: Grovs::Platforms::IOS)
    assert_equal 700, android.revenue, "credit moves to the device platform"
    assert_equal(-700, ios.revenue, "processing-time credit is reversed, not duplicated")
  end

  test "skips visitor and link revenue when revenue_delta is nil (subscription cancel)" do
    event = create_purchase_event(
      device: @ios_device,
      link: @link,
      store_source: Grovs::Webhooks::APPLE,
      usd_price_cents: 999,
      event_type: Grovs::Purchases::EVENT_CANCEL,
      purchase_type: Grovs::Purchases::TYPE_SUBSCRIPTION
    )
    assert_nil event.revenue_delta, "Subscription cancel should have nil revenue_delta"

    vds_before = VisitorDailyStatistic.count
    lds_before = LinkDailyStatistic.count

    @job.perform(event.id)

    # No new revenue stats created because revenue_delta is nil => revenue is 0
    assert_equal vds_before, VisitorDailyStatistic.count
    assert_equal lds_before, LinkDailyStatistic.count
  end

  # --- Same platform: device attribution ---

  test "records device attribution via InAppProductEventService when platform unchanged" do
    event = create_purchase_event(
      device: @ios_device,
      store_source: Grovs::Webhooks::APPLE, # ios device, apple store => same platform
      usd_price_cents: 300,
      event_type: Grovs::Purchases::EVENT_BUY,
      product_id: "com.test.same_plat"
    )

    @job.perform(event.id)

    # InAppProduct should be created via record_device_attribution
    iap = InAppProduct.find_by(project_id: @project.id, product_id: "com.test.same_plat", platform: Grovs::Platforms::IOS)
    assert_not_nil iap, "Should create InAppProduct via device attribution"
  end

  test "does NOT record device attribution when platform changed (already handled by record_purchase)" do
    event = create_purchase_event(
      device: @ios_device,
      store_source: Grovs::Webhooks::GOOGLE, # android store, ios device => platform changed
      usd_price_cents: 300,
      event_type: Grovs::Purchases::EVENT_BUY,
      product_id: "com.test.changed_plat"
    )

    @job.perform(event.id)

    # Product should exist on the NEW platform (ios) from record_purchase, NOT from record_device_attribution
    iap_new = InAppProduct.find_by(project_id: @project.id, product_id: "com.test.changed_plat", platform: Grovs::Platforms::IOS)
    assert_not_nil iap_new, "record_purchase should create product on new platform"
  end

  # --- SubscriptionState ---

  test "upserts subscription state for every event" do
    orig_txn = "reattr_sub_orig_#{SecureRandom.hex(4)}"
    event = create_purchase_event(
      device: @ios_device,
      store_source: Grovs::Webhooks::APPLE,
      usd_price_cents: 999,
      event_type: Grovs::Purchases::EVENT_BUY,
      original_transaction_id: orig_txn
    )

    @job.perform(event.id)

    state = SubscriptionState.find_by(project_id: @project.id, original_transaction_id: orig_txn)
    assert_not_nil state
    assert_equal @ios_device.id, state.device_id
  end

  # --- Guard clauses ---

  test "returns nil for nonexistent event" do
    result = @job.perform(999999)
    assert_nil result
  end

  test "returns nil for event without device" do
    event = purchase_events(:no_device_buy)
    assert_nil event.device_id
    result = @job.perform(event.id)
    assert_nil result
  end

  # --- DLQ ---

  test "DLQ handler creates FailedPurchaseJob with correct fields" do
    event = purchase_events(:buy_event)
    job_hash = {
      'class' => 'ReattributePurchaseJob',
      'args' => [event.id],
      'error_class' => 'RuntimeError',
      'error_message' => 'connection timeout'
    }

    assert_difference "FailedPurchaseJob.count", 1 do
      ReattributePurchaseJob.sidekiq_retries_exhausted_block.call(job_hash, nil)
    end

    failed = FailedPurchaseJob.last
    assert_equal 'ReattributePurchaseJob', failed.job_class
    assert_equal event.id, failed.purchase_event_id
    assert_equal @project.id, failed.project_id
  end

  private

  test "platform move transfers the full quantity, not 1" do
    event = create_purchase_event(
      device: @ios_device, store_source: Grovs::Webhooks::GOOGLE,
      usd_price_cents: 100, event_type: Grovs::Purchases::EVENT_BUY
    )
    event.update_columns(quantity: 3)

    @job.perform(event.id)

    new_metric = DailyProjectMetric.find_by(project_id: @project.id, platform: Grovs::Platforms::IOS, event_date: Date.current)
    old_metric = DailyProjectMetric.find_by(project_id: @project.id, platform: Grovs::Platforms::ANDROID, event_date: Date.current)
    assert_equal 3, new_metric.units_sold
    assert_equal 300, new_metric.revenue, "revenue is quantity-weighted"
    assert_equal(-3, old_metric.units_sold)
  end

  test "same-platform reattribution does not re-add link revenue credited at processing" do
    event = create_purchase_event(
      device: nil, store_source: Grovs::Webhooks::GOOGLE, link: @link,
      usd_price_cents: 999, event_type: Grovs::Purchases::EVENT_BUY
    )
    event.update_columns(processed: false)
    ProcessPurchaseEventJob.new.perform(event.id) # credits link under android (store)
    event.update!(device: devices(:android_device)) # same platform arrives late

    @job.perform(event.id)

    total = LinkDailyStatistic.where(project_id: @project.id, link_id: @link.id,
                                     event_date: Date.current).sum(:revenue)
    assert_equal 999, total, "link revenue must not double on same-platform reattribution"
  end

  test "cross-platform reattribution moves link revenue instead of adding it" do
    event = create_purchase_event(
      device: nil, store_source: Grovs::Webhooks::GOOGLE, link: @link,
      usd_price_cents: 999, event_type: Grovs::Purchases::EVENT_BUY
    )
    event.update_columns(processed: false)
    ProcessPurchaseEventJob.new.perform(event.id)
    event.update!(device: @ios_device)

    @job.perform(event.id)

    by_platform = LinkDailyStatistic.where(project_id: @project.id, link_id: @link.id,
                                           event_date: Date.current)
                                    .group(:platform).sum(:revenue)
    assert_equal 999, by_platform["ios"].to_i
    assert_equal 0, by_platform.fetch("android", 0).to_i, "old-platform credit removed"
  end

  test "updates ledger snapshots to the device platform and resolved visitor" do
    event = create_purchase_event(
      device: @ios_device, store_source: Grovs::Webhooks::GOOGLE,
      usd_price_cents: 999, event_type: Grovs::Purchases::EVENT_BUY
    )
    event.update_columns(revenue_platform: Grovs::Platforms::ANDROID) # initial store snapshot

    @job.perform(event.id)

    event.reload
    assert_equal Grovs::Platforms::IOS, event.revenue_platform, "reattribution moves the snapshot to the device platform"
    assert_equal visitors(:ios_visitor).id, event.visitor_id
  end

  def create_purchase_event(device:, store_source:, usd_price_cents:, event_type:, link: nil,
                            product_id: "com.test.reattr", purchase_type: Grovs::Purchases::TYPE_SUBSCRIPTION,
                            original_transaction_id: nil)
    PurchaseEvent.create!(
      event_type: event_type,
      project: @project,
      device: device,
      link: link,
      identifier: "com.test.app",
      price_cents: usd_price_cents, currency: "USD", usd_price_cents: usd_price_cents,
      date: Date.current,
      transaction_id: "reattr_#{SecureRandom.hex(6)}",
      original_transaction_id: original_transaction_id || "reattr_orig_#{SecureRandom.hex(6)}",
      product_id: product_id,
      store_source: store_source,
      webhook_validated: true, store: true, processed: true,
      purchase_type: purchase_type
    )
  end
end
