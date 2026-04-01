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

  # --- Platform change: DailyProjectMetric corrections ---

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

  test "increments link daily stat revenue when event has link_id" do
    event = create_purchase_event(
      device: @ios_device,
      link: @link,
      store_source: Grovs::Webhooks::APPLE,
      usd_price_cents: 700,
      event_type: Grovs::Purchases::EVENT_BUY
    )

    @job.perform(event.id)

    lds = LinkDailyStatistic.find_by(link_id: @link.id, event_date: Date.current, platform: Grovs::Platforms::IOS)
    assert_not_nil lds
    assert_equal 700, lds.revenue
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
