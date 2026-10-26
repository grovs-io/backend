require "test_helper"
require "sidekiq/testing"
require "ostruct"

class PurchaseConcurrencyTest < ActiveSupport::TestCase
  include ConcurrencyHelper
  include ClickhouseTestHelper

  self.use_transactional_tests = false # each job claims on its own connection; teardown cleans by hand

  fixtures :instances, :projects, :domains, :redirect_configs, :applications, :ios_configurations

  DAY = Date.new(2026, 7, 14)
  PRICE = 499
  QUANTITY = 2

  setup do
    skip_unless_clickhouse!
    ensure_pool!
    Sidekiq::Testing.fake!
    Sidekiq::Worker.clear_all
    @started_at = Time.current - 1
    @tag = SecureRandom.hex(4)
    @project = projects(:one)
    @product_id = "conc.product.#{@tag}"
    @link = Link.create!(domain: domains(:one), redirect_config: redirect_configs(:one),
                         path: "conc-iap-#{@tag}", generated_from_platform: "ios")
    @devices = []
    @visitors = []
  end

  teardown do
    next unless concurrency_enabled?

    Sidekiq::Worker.clear_all
    event_ids = PurchaseEvent.where(project_id: [@project&.id, projects(:one_test).id]).where("transaction_id LIKE ?", "conc-%").pluck(:id)
    PurchaseEvent.where(id: event_ids).delete_all
    SubscriptionState.where("original_transaction_id LIKE ?", "conc-%").delete_all
    DeviceProductPurchase.where(product_id: @product_id).delete_all
    product_ids = InAppProduct.where(product_id: @product_id).pluck(:id)
    InAppProductDailyStatistic.where(in_app_product_id: product_ids).delete_all
    InAppProduct.where(id: product_ids).delete_all
    DailyProjectMetric.where(project_id: [@project&.id, projects(:one_test).id], event_date: DAY).delete_all
    IapWebhookMessage.where(created_at: @started_at..).delete_all
    LinkDailyStatistic.where(link_id: @link&.id).delete_all
    VisitorDailyStatistic.where(visitor_id: @visitors.map(&:id)).delete_all
    DeviceLastSeen.where(device_id: @devices.map(&:id)).delete_all
    Link.where(id: @link&.id).delete_all
    Visitor.where(id: @visitors.map(&:id)).delete_all
    Device.where(id: @devices.map(&:id)).delete_all
  end

  # Catches: dropping the `processed: false` claim, which counts one purchase once per racing job.
  test "the same purchase processed by many jobs at once is counted once everywhere" do
    event = create_purchase(transaction_id: "conc-same-#{@tag}", device: new_device)

    run_concurrently { ProcessPurchaseEventJob.new.perform(event.id) }

    revenue = PRICE * QUANTITY
    dpm = DailyProjectMetric.find_by!(project_id: @project.id, event_date: DAY, platform: Grovs::Platforms::IOS)
    assert_equal [revenue, QUANTITY], [dpm.revenue, dpm.units_sold]
    assert_equal revenue, LinkDailyStatistic.where(link_id: @link.id).sum(:revenue)
    assert_equal revenue, VisitorDailyStatistic.where(visitor_id: @visitors.map(&:id)).sum(:revenue)
    stats = InAppProductDailyStatistic.joins(:in_app_product).where(in_app_products: { product_id: @product_id })
    assert_equal [revenue, QUANTITY, 1], [stats.sum(:revenue), stats.sum(:purchase_events), stats.sum(:first_time_purchases)]
    assert_equal 1, InAppProduct.find_by!(product_id: @product_id).unique_purchasing_devices
    assert_equal 1, ch_purchase_rows(event.transaction_id), "ClickHouse ledger: one purchase row after FINAL"
  end

  # Catches: LinkDailyStatService.increment_link_event's RecordNotUnique `retry` inside the claim transaction.
  test "distinct purchases on one link racing for its first stat row of the day: no job fails" do
    events = Array.new(scaled(THREADS * 3)) { |i| create_purchase(transaction_id: "conc-many-#{@tag}-#{i}", device: new_device) }
    errors = run_concurrently do |t|
      events.select.with_index { |_, j| j % THREADS == t }.filter_map do |event|
        ProcessPurchaseEventJob.new.perform(event.id)
        nil
      rescue StandardError => e
        "#{e.class}: #{e.message.lines.first.strip}"
      end
    end.flatten

    assert_empty errors, "#{errors.size}/#{events.size} purchase jobs raised (each rolls back and waits for a Sidekiq retry)"
    revenue = PRICE * QUANTITY * events.size
    dpm = DailyProjectMetric.find_by!(project_id: @project.id, event_date: DAY, platform: Grovs::Platforms::IOS)
    assert_equal [revenue, QUANTITY * events.size], [dpm.revenue, dpm.units_sold]
    assert_equal revenue, LinkDailyStatistic.where(link_id: @link.id).sum(:revenue)
    assert_equal revenue, VisitorDailyStatistic.where(visitor_id: @visitors.map(&:id)).sum(:revenue)
    assert_equal events.size, InAppProduct.find_by!(product_id: @product_id).unique_purchasing_devices
    assert_equal events.size, PurchaseEvent.where(id: events.map(&:id), processed: true).count
  end

  # Catches: the webhook check-then-create without the unique index + RecordNotUnique fallback.
  test "the same Apple notification delivered concurrently creates one purchase, counted once" do
    txn = "conc-apple-#{@tag}"
    receipts = apple_receipts(txn)

    results = AppStoreServerApi::Utils::Decoder.stub(:decode_jws!, ->(jws) { receipts.fetch(jws) }) do
      run_concurrently { AppleIapService.new.handle_notification({ "signedPayload" => "outer" }, @project) }
    end

    assert_equal [true] * THREADS, results, "every delivery must be acknowledged, not 500 into an Apple retry"
    assert_equal 1, PurchaseEvent.where(project_id: @project.id, transaction_id: txn).count
    assert_equal THREADS, IapWebhookMessage.where(project_id: @project.id, notification_type: "ONE_TIME_CHARGE").count
    assert_equal 1, ProcessPurchaseEventJob.jobs.size, "only the creator enqueues processing"

    drain_purchase_jobs
    dpm = DailyProjectMetric.find_by!(project_id: @project.id, event_date: DAY, platform: Grovs::Platforms::IOS)
    assert_equal PRICE, dpm.revenue
    assert_equal 1, ch_purchase_rows(txn)
  end

  # Catches: the same race on the Google RTDN path (one job per Pub/Sub redelivery).
  test "the same Google notification delivered concurrently creates one purchase, counted once" do
    token = "conc-google-#{@tag}"
    instance = instances(:one)
    messages = Array.new(THREADS) do
      IapWebhookMessage.create!(payload: { token: token }.to_json, source: Grovs::Webhooks::GOOGLE, instance: instance)
    end
    notification = { "packageName" => "com.test.app",
                     "oneTimeProductNotification" => { "purchaseToken" => token, "sku" => @product_id } }
    service = google_service

    results = IapUtils.stub(:build_google_service, ->(_) { service }) do
      IapUtils.stub(:fetch_google_product_details, ->(*) { OpenStruct.new(default_price: OpenStruct.new(price_micros: PRICE * 10_000, currency: "USD")) }) do
        run_concurrently { |i| ProcessGoogleNotificationJob.new.perform(messages[i].id, notification, instance.id) }
      end
    end

    assert_equal [true] * THREADS, results, "every redelivery must be handled, not dropped as an error"
    production = instance.production
    assert_equal 1, PurchaseEvent.where(project_id: production.id, transaction_id: token).count
    assert_equal 1, ProcessPurchaseEventJob.jobs.size

    drain_purchase_jobs
    dpm = DailyProjectMetric.find_by!(project_id: production.id, event_date: DAY, platform: Grovs::Platforms::ANDROID)
    assert_equal PRICE, dpm.revenue
  end

  private

  def new_device
    device = Device.create!(user_agent: "ConcIap/1", ip: "10.51.0.1", remote_ip: "10.52.0.1", platform: "ios",
                            vendor: "conc-iap-#{SecureRandom.hex(6)}")
    @devices << device
    @visitors << Visitor.create!(project: @project, device: device)
    device
  end

  def create_purchase(transaction_id:, device:)
    PurchaseEvent.create!(project: @project, device: device, link: @link, event_type: Grovs::Purchases::EVENT_BUY,
                          purchase_type: Grovs::Purchases::TYPE_ONE_TIME, product_id: @product_id,
                          usd_price_cents: PRICE, quantity: QUANTITY, transaction_id: transaction_id,
                          original_transaction_id: transaction_id, store_source: Grovs::Webhooks::APPLE,
                          webhook_validated: true, store: true, date: DAY.in_time_zone("UTC") + 10.hours)
  end

  def apple_receipts(txn)
    {
      "outer" => { "notificationType" => "ONE_TIME_CHARGE",
                   "data" => { "bundleId" => "com.test.iosapp", "signedTransactionInfo" => "txn" } },
      "txn" => { "transactionId" => txn, "originalTransactionId" => txn, "productId" => @product_id,
                 "bundleId" => "com.test.iosapp", "price" => PRICE * 10, "currency" => "USD",
                 "purchaseDate" => (DAY.in_time_zone("UTC") + 10.hours).to_i * 1000, "environment" => "Sandbox" }
    }
  end

  def google_service
    purchase = OpenStruct.new(purchase_type: 1, purchase_time_millis: (DAY.in_time_zone("UTC") + 10.hours).to_i * 1000,
                              order_id: "GPA.conc-#{@tag}", quantity: 1)
    Object.new.tap do |svc|
      svc.define_singleton_method(:get_purchase_product) { |*| purchase }
      svc.define_singleton_method(:acknowledge_purchase_product) { |*| nil }
    end
  end

  def drain_purchase_jobs
    ids = ProcessPurchaseEventJob.jobs.map { |j| j["args"].first }
    ProcessPurchaseEventJob.clear
    run_concurrently { ids.each { |id| ProcessPurchaseEventJob.new.perform(id) } }
  end

  def ch_purchase_rows(transaction_id)
    Clickhouse.with do |c|
      c.select_value("SELECT count() FROM purchase_events FINAL WHERE transaction_id = '#{transaction_id}'").to_i
    end
  end
end
