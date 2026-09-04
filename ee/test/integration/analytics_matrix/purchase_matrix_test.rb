# frozen_string_literal: true

require "test_helper"

# EE purchase reconciliation via ProcessPurchaseEventJob: PG (processed + NET
# DailyProjectMetric revenue), CH purchase_events, and the signed purchase_*_daily
# rollups. The rollups now SIGN revenue + units to match PurchaseEvent#revenue_delta
# / units_sold (refund -, cancel-sub 0, units only for buy?). Run with GROVS_EE=true.
class PurchaseMatrixTest < ActiveSupport::TestCase
  include ClickhouseTestHelper

  fixtures :instances, :projects, :devices, :visitors, :purchase_events, :domains,
           :links, :in_app_products, :in_app_product_daily_statistics, :subscription_states

  PURCHASE_DATE = Time.utc(2026, 4, 1, 10, 30, 0)

  setup do
    skip_unless_clickhouse!
    @project = projects(:one)
    @orig_ch_write = Rails.application.config.clickhouse_write_enabled
    Rails.application.config.clickhouse_write_enabled = true
    truncate_clickhouse_tables
    # Clean PG slate: purchase fixtures + the rollup table this test asserts on.
    PurchaseEvent.where(project_id: @project.id).delete_all
    DailyProjectMetric.where(project_id: @project.id).delete_all
  end

  teardown do
    Rails.application.config.clickhouse_write_enabled = @orig_ch_write if defined?(@orig_ch_write)
  end

  def create_event(attrs = {})
    PurchaseEvent.create!({
      event_type: Grovs::Purchases::EVENT_BUY,
      device: devices(:ios_device),
      project: @project,
      identifier: "com.test.app",
      price_cents: 999, currency: "USD", usd_price_cents: 999,
      date: PURCHASE_DATE,
      transaction_id: "txn_#{SecureRandom.hex(6)}",
      original_transaction_id: "orig_#{SecureRandom.hex(6)}",
      product_id: "com.test.premium",
      webhook_validated: true, store: true, processed: false,
      purchase_type: Grovs::Purchases::TYPE_SUBSCRIPTION,
      store_source: Grovs::Webhooks::APPLE
    }.merge(attrs))
  end

  def ch_purchase_row(transaction_id)
    ch_query("purchase_events", @project.id, extra_where: "transaction_id = '#{transaction_id}'").first
  end

  # Reads are scoped to the purchase DATE so a regression writing created_at/today
  # instead of event.date (wrong daily bucket) is caught, not summed away.
  def project_daily_purchase(event_type, store_source: nil)
    where = "project_id = #{@project.id} AND event_type = '#{event_type}' " \
            "AND event_date = '#{PURCHASE_DATE.to_date}'"
    where += " AND store_source = '#{store_source}'" if store_source
    Clickhouse.with do |c|
      c.select_one(
        "SELECT sum(total_revenue_cents) AS rev, sum(units) AS units, " \
        "uniq(visitor_id) AS payers FROM purchase_project_daily WHERE #{where}"
      )
    end
  end

  def product_daily(product_id)
    Clickhouse.with do |c|
      c.select_one(
        "SELECT sum(total_revenue_cents) AS rev, sum(units) AS units FROM purchase_product_daily FINAL " \
        "WHERE project_id = #{@project.id} AND product_id = '#{product_id}' " \
        "AND event_date = '#{PURCHASE_DATE.to_date}'"
      )
    end
  end

  def pg_revenue
    DailyProjectMetric.where(project_id: @project.id, event_date: PURCHASE_DATE.to_date).sum(:revenue)
  end

  test "a buy event reconciles PG, CH purchase_events, and both rollups" do
    event = create_event(usd_price_cents: 1499, product_id: "com.test.annual")
    ProcessPurchaseEventJob.new.perform(event.id)

    assert event.reload.processed?, "event should be marked processed"

    # CH purchase_events row
    row = ch_purchase_row(event.transaction_id)
    assert_not_nil row, "expected a CH purchase_events row"
    assert_equal "buy", row["event_type"]
    assert_equal "subscription", row["purchase_type"]
    assert_equal 1499, row["usd_price_cents"].to_i
    assert_equal "com.test.annual", row["product_id"]
    assert_equal "apple", row["store_source"]
    assert_equal devices(:ios_device).id, row["device_id"].to_i

    # purchase_project_daily (AggregatingMergeTree): gross revenue + units, uniq payers
    prd = project_daily_purchase("buy")
    assert_equal 1499, prd["rev"].to_i
    assert_equal 1, prd["units"].to_i
    assert_equal 1, prd["payers"].to_i

    # purchase_product_daily (signed ReplacingMergeTree): revenue + units per product
    ppd = product_daily("com.test.annual")
    assert_equal 1499, ppd["rev"].to_i
    assert_equal 1, ppd["units"].to_i

    # PG DailyProjectMetric: NET revenue (a buy == +price), on the purchase date
    assert_equal 1499, pg_revenue
  end

  # The matrix: event types x purchase types x stores x with/without device.
  # Independent oracle tallies GROSS per event_type/product (what CH sums) and
  # NET revenue (signed revenue_delta — what DailyProjectMetric sums).
  SCENARIOS = [
    { type: Grovs::Purchases::EVENT_BUY,             ptype: Grovs::Purchases::TYPE_SUBSCRIPTION, store: Grovs::Webhooks::APPLE,  price: 1000, product: "p.annual", device: :ios_device },
    { type: Grovs::Purchases::EVENT_REFUND,          ptype: Grovs::Purchases::TYPE_ONE_TIME,     store: Grovs::Webhooks::GOOGLE, price: 300,  product: "p.coins",  device: :android_device },
    { type: Grovs::Purchases::EVENT_REFUND_REVERSED, ptype: Grovs::Purchases::TYPE_SUBSCRIPTION, store: Grovs::Webhooks::APPLE,  price: 500,  product: "p.annual", device: :ios_device },
    { type: Grovs::Purchases::EVENT_CANCEL,          ptype: Grovs::Purchases::TYPE_SUBSCRIPTION, store: Grovs::Webhooks::APPLE,  price: 700,  product: "p.annual", device: :ios_device },
    { type: Grovs::Purchases::EVENT_CANCEL,          ptype: Grovs::Purchases::TYPE_ONE_TIME,     store: Grovs::Webhooks::GOOGLE, price: 200,  product: "p.coins",  device: nil }
  ].freeze

  test "the purchase matrix reconciles gross CH rollups and net PG revenue" do
    SCENARIOS.each do |s|
      device = s[:device] ? devices(s[:device]) : nil
      event = create_event(
        event_type: s[:type], purchase_type: s[:ptype], store_source: s[:store],
        usd_price_cents: s[:price], price_cents: s[:price], product_id: s[:product],
        device: device
      )
      ProcessPurchaseEventJob.new.perform(event.id)

      # Per-row CH dimensions (not just price) — a mis-mapped event_type/
      # purchase_type/store_source/device_id would otherwise hide inside the
      # cross-dimension rollup sums below.
      row = ch_purchase_row(event.transaction_id)
      assert_not_nil row, "missing CH row for #{s[:type]}/#{s[:product]}"
      assert_equal s[:price], row["usd_price_cents"].to_i
      assert_equal s[:type],  row["event_type"]
      assert_equal s[:ptype], row["purchase_type"]
      assert_equal s[:store], row["store_source"]
      assert_equal (device&.id || 0), row["device_id"].to_i
    end

    # SIGNED per event_type in purchase_project_daily (matches revenue_delta).
    # refund -300; refund_reversed +500; cancel = sub(0) + one_time(-200) = -200.
    # units = quantity only for buy?-type (buy / refund_reversed).
    {
      "buy" => [1000, 1], "refund" => [-300, 0],
      "refund_reversed" => [500, 1], "cancel" => [-200, 0]
    }.each do |event_type, (rev, units)|
      prd = project_daily_purchase(event_type)
      assert_equal rev, prd["rev"].to_i, "signed revenue for #{event_type}"
      assert_equal units, prd["units"].to_i, "units for #{event_type}"
    end

    # SIGNED per product in purchase_product_daily.
    # p.annual: buy 1000 + refund_reversed 500 + cancel-sub 0 = 1500; units = 2.
    assert_equal 1500, product_daily("p.annual")["rev"].to_i
    assert_equal 2,    product_daily("p.annual")["units"].to_i
    # p.coins: refund-one_time -300 + cancel-one_time -200 = -500; units = 0.
    assert_equal(-500, product_daily("p.coins")["rev"].to_i)
    assert_equal 0,    product_daily("p.coins")["units"].to_i

    # NET revenue in PG: +1000 (buy) -300 (refund) +500 (refund_reversed)
    #   +0 (cancel-SUBSCRIPTION: revenue_delta nil) -200 (cancel ONE_TIME).
    assert_equal 1000, pg_revenue,
                 "net revenue applies signed revenue_delta; cancel-subscription contributes 0"

    # units_sold and cancellations carry the buy?/cancellation? semantics and are
    # a separate output column: units_sold = buy(1) + refund_reversed(1) = 2;
    # cancellations = cancel-sub(1) + cancel-one_time(1) + refund-one_time(1) = 3.
    by_date = DailyProjectMetric.where(project_id: @project.id, event_date: PURCHASE_DATE.to_date)
    assert_equal 2, by_date.sum(:units_sold),    "buy + refund_reversed are buy?"
    assert_equal 3, by_date.sum(:cancellations), "cancel(any) + refund(one_time) are cancellation?"
  end

  # quantity>1: PG and CH must AGREE. usd_price_cents is a unit price on the row,
  # but the rollups quantity-weight it: revenue = sum(usd_price_cents * quantity),
  # units = sum(quantity) — matching PG's revenue_delta / units_sold. (Fixed in
  # migration 20260624000001; previously CH summed unit prices and count()-ed
  # rows, under-reporting Google multi-quantity refunds/bundles.)
  test "quantity>1 is quantity-weighted consistently in PG and CH" do
    event = create_event(usd_price_cents: 1000, quantity: 3, product_id: "p.bundle")
    ProcessPurchaseEventJob.new.perform(event.id)

    # Raw CH row keeps the unit price + quantity separately.
    row = ch_purchase_row(event.transaction_id)
    assert_equal 1000, row["usd_price_cents"].to_i, "raw row stores the unit price"
    assert_equal 3,    row["quantity"].to_i

    # Rollups are quantity-weighted (gross revenue + items), matching PG.
    prd = project_daily_purchase("buy")
    assert_equal 3000, prd["rev"].to_i,   "CH gross revenue = usd x quantity"
    assert_equal 3,    prd["units"].to_i, "CH units = sum(quantity)"
    assert_equal 3000, product_daily("p.bundle")["rev"].to_i
    assert_equal 3,    product_daily("p.bundle")["units"].to_i

    assert_equal 3000, pg_revenue, "PG net revenue = usd x quantity"
    by_date = DailyProjectMetric.where(project_id: @project.id, event_date: PURCHASE_DATE.to_date)
    assert_equal 3, by_date.sum(:units_sold), "PG units_sold = quantity"
  end

  test "paying_visitors counts DISTINCT visitors, not purchase rows" do
    # Two buys by the SAME visitor (ios) + one by a different visitor (android)
    # = 3 rows but 2 distinct payers. uniqMerge must report 2, not 3.
    2.times { ProcessPurchaseEventJob.new.perform(create_event(device: devices(:ios_device), usd_price_cents: 100).id) }
    ProcessPurchaseEventJob.new.perform(create_event(device: devices(:android_device), usd_price_cents: 100).id)

    prd = project_daily_purchase("buy")
    assert_equal 3, prd["units"].to_i, "3 purchase rows"
    assert_equal 2, prd["payers"].to_i, "2 DISTINCT paying visitors (uniq, not count)"
  end

  # The processed-guard prevents double-processing, so only one rollup row exists
  # here (non-FINAL read). The signed rollups are also ReplacingMergeTree keyed by
  # transaction_id, so a duplicate dual-write would additionally dedup under FINAL.
  test "replaying a processed event does not double-count PG or the rollups" do
    event = create_event(usd_price_cents: 800)
    ProcessPurchaseEventJob.new.perform(event.id)
    rev_before   = pg_revenue
    units_before = project_daily_purchase("buy")["units"].to_i

    ProcessPurchaseEventJob.new.perform(event.id) # replay (Sidekiq retry / dup webhook)

    assert_equal rev_before, pg_revenue, "PG net revenue unchanged on replay"
    assert_equal units_before, project_daily_purchase("buy")["units"].to_i,
                 "rollup units unchanged — MVs would double-count without the processed guard"
  end

  test "purchase rollups are isolated per project" do
    p2 = projects(:two)
    p1_event = create_event(usd_price_cents: 100, product_id: "p.annual")
    p2_event = PurchaseEvent.create!(
      event_type: Grovs::Purchases::EVENT_BUY, project: p2, device: nil,
      identifier: "com.test.app", price_cents: 999, currency: "USD", usd_price_cents: 999,
      date: PURCHASE_DATE, transaction_id: "txn_p2_#{SecureRandom.hex(6)}",
      original_transaction_id: "orig_p2_#{SecureRandom.hex(6)}", product_id: "p.annual",
      webhook_validated: true, store: true, processed: false,
      purchase_type: Grovs::Purchases::TYPE_SUBSCRIPTION, store_source: Grovs::Webhooks::APPLE
    )
    ProcessPurchaseEventJob.new.perform(p1_event.id)
    ProcessPurchaseEventJob.new.perform(p2_event.id)

    assert_equal 100, project_daily_purchase("buy")["rev"].to_i, "p1 rollup sees only its own 100"
    p2_rev = Clickhouse.with do |c|
      c.select_value(
        "SELECT sum(total_revenue_cents) FROM purchase_project_daily " \
        "WHERE project_id = #{p2.id} AND event_type = 'buy' AND event_date = '#{PURCHASE_DATE.to_date}'"
      )
    end
    assert_equal 999, p2_rev.to_i, "p2 keeps its own 999, no leak from p1"
  end
end
