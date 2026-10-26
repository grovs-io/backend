# frozen_string_literal: true

require "test_helper"

class ProcessPurchaseEventClickhouseTest < ActiveSupport::TestCase
  include ClickhouseTestHelper

  fixtures :instances, :projects, :devices, :visitors, :purchase_events, :domains, :links,
           :in_app_products, :in_app_product_daily_statistics, :subscription_states

  setup do
    skip_unless_clickhouse!

    @job = ProcessPurchaseEventJob.new
    @project = projects(:one)

    @original_ch_enabled = Rails.application.config.clickhouse_write_enabled
    Rails.application.config.clickhouse_write_enabled = true
  end

  teardown do
    Rails.application.config.clickhouse_write_enabled = @original_ch_enabled if defined?(@original_ch_enabled)
    REDIS.scan_each(match: "purchase:sync:*") { |k| REDIS.del(k) }
  end

  # --- helpers ---

  def ch_purchase_rows(project_id, extra_where: nil)
    ch_query('purchase_events', project_id, extra_where: extra_where)
  end

  def ch_time(value)
    value.is_a?(Time) ? value : Time.parse(value.to_s)
  end

  def ch_final_rows(event)
    Clickhouse.with do |c|
      c.select_all("SELECT * FROM purchase_events FINAL WHERE project_id = #{event.project_id} " \
                   "AND transaction_id = '#{event.transaction_id}' AND event_type = '#{event.event_type}'").to_a
    end
  end

  def latest_ch_row(event) = ch_final_rows(event).first

  def ch_final_count(event) = ch_final_rows(event).size

  def ch_rollup_rows(table, where)
    Clickhouse.with { |c| c.select_all("SELECT * FROM #{table} FINAL WHERE project_id = #{@project.id} AND #{where}").to_a }
  end

  def pg_revenue(project)
    DailyProjectMetric.where(project_id: project.id).sum(:revenue)
  end

  def ch_purchase_count(project_id)
    Clickhouse.with { |conn| conn.select_value("SELECT COUNT(*) FROM purchase_events WHERE project_id = #{Integer(project_id)}") }
  end

  def create_unprocessed_event(attrs = {})
    PurchaseEvent.create!({
      event_type: Grovs::Purchases::EVENT_BUY,
      device: devices(:ios_device),
      project: @project,
      identifier: "com.test.app",
      price_cents: 999, currency: "USD", usd_price_cents: 999,
      date: Time.utc(2026, 4, 1, 10, 30, 0),
      transaction_id: "txn_ch_#{SecureRandom.hex(4)}",
      original_transaction_id: "orig_ch_#{SecureRandom.hex(4)}",
      product_id: "com.test.premium",
      webhook_validated: true,
      store: true,
      purchase_type: Grovs::Purchases::TYPE_SUBSCRIPTION,
      store_source: Grovs::Webhooks::APPLE
    }.merge(attrs))
  end

  test "all CH columns populated correctly from a buy event with device and link" do
    link = links(:basic_link)
    device = devices(:ios_device)
    visitor = device.visitor_for_project_id(@project.id)
    event = create_unprocessed_event(
      device: device,
      link: link,
      usd_price_cents: 1499,
      price_cents: 1499,
      currency: "EUR",
      quantity: 2,
      store_source: Grovs::Webhooks::APPLE,
      purchase_type: Grovs::Purchases::TYPE_SUBSCRIPTION,
      product_id: "com.test.annual",
      session_id: "sess-ch"
    )

    @job.perform(event.id)

    rows = ch_purchase_rows(@project.id, extra_where: "transaction_id = '#{event.transaction_id}'")
    assert_equal 1, rows.size, "Exactly one CH row expected"

    row = rows.first
    assert_equal @project.id,                 row["project_id"]
    assert_equal Grovs::Purchases::EVENT_BUY, row["event_type"]
    assert_equal "subscription",              row["purchase_type"]
    assert_equal "com.test.annual",           row["product_id"]
    assert_equal 1499,                        row["usd_price_cents"]
    assert_equal "EUR",                       row["currency"]
    assert_equal 2,                           row["quantity"]
    assert_equal event.transaction_id,        row["transaction_id"]
    assert_equal event.original_transaction_id, row["original_transaction_id"]
    assert_equal "apple",                     row["store_source"]
    assert_equal device.id,                   row["device_id"]
    assert_equal link.id,                     row["link_id"]
    assert_equal visitor.id,                  row["visitor_id"]
    assert_equal "sess-ch",                   row["session_id"]

    # purchase_date should match event.date (not created_at)
    ch_purchase_date = Time.parse(row["purchase_date"].to_s).utc
    assert_in_delta event.date.to_time.utc.to_f, ch_purchase_date.to_f, 1.0,
                    "purchase_date should match event.date"

    # created_at should be close to event.created_at
    ch_created = Time.parse(row["created_at"].to_s).utc
    assert_in_delta event.created_at.to_f, ch_created.to_f, 1.0,
                    "created_at should match event.created_at"
  end

  test "purchase without device: device_id=0, visitor_id=0, link_id=0" do
    event = create_unprocessed_event(device: nil, link: nil)

    @job.perform(event.id)

    rows = ch_purchase_rows(@project.id, extra_where: "transaction_id = '#{event.transaction_id}'")
    assert_equal 1, rows.size
    assert_equal 0, rows.first["device_id"]
    assert_equal 0, rows.first["visitor_id"]
    assert_equal 0, rows.first["link_id"]
  end

  test "nil usd_price_cents written as 0 to CH" do
    event = create_unprocessed_event(
      usd_price_cents: nil,
      price_cents: nil,
      currency: nil
    )

    @job.perform(event.id)

    rows = ch_purchase_rows(@project.id, extra_where: "transaction_id = '#{event.transaction_id}'")
    assert_equal 0, rows.first["usd_price_cents"], "nil usd_price_cents should become 0 in CH"
    assert_equal "", rows.first["currency"], "nil currency should become empty string in CH"
  end

  test "nil store_source written as empty string to CH" do
    event = create_unprocessed_event(store_source: nil)

    @job.perform(event.id)

    rows = ch_purchase_rows(@project.id, extra_where: "transaction_id = '#{event.transaction_id}'")
    assert_equal "", rows.first["store_source"]
  end

  test "cancel event lands in CH with correct event_type" do
    event = create_unprocessed_event(event_type: Grovs::Purchases::EVENT_CANCEL)

    @job.perform(event.id)

    rows = ch_purchase_rows(@project.id, extra_where: "transaction_id = '#{event.transaction_id}'")
    assert_equal 1, rows.size
    assert_equal Grovs::Purchases::EVENT_CANCEL, rows.first["event_type"]
  end

  test "refund event lands in CH with correct event_type and purchase_type" do
    event = create_unprocessed_event(
      event_type: Grovs::Purchases::EVENT_REFUND,
      purchase_type: Grovs::Purchases::TYPE_ONE_TIME
    )

    @job.perform(event.id)

    rows = ch_purchase_rows(@project.id, extra_where: "transaction_id = '#{event.transaction_id}'")
    assert_equal 1, rows.size
    assert_equal Grovs::Purchases::EVENT_REFUND, rows.first["event_type"]
    assert_equal "one_time", rows.first["purchase_type"]
  end

  test "CH failure parks the purchase in the DLQ and does not block PG processing" do
    event = create_unprocessed_event
    REDIS.with { |c| c.del(ClickhouseWriteService::PURCHASE_DLQ_KEY) }

    # raw_insert is the real CH seam; failing it makes deliver_purchase_events exhaust its
    # bounded retries and park the batch in the DLQ (recoverable) rather than dropping it.
    ClickhouseWriteService.stub(:raw_insert, ->(_t, _r) { raise StandardError, "CH down" }) do
      @job.perform(event.id)
    end

    event.reload
    assert event.processed?, "PG processed flag must be set even when CH fails"
    metric = DailyProjectMetric.find_by(project_id: @project.id, event_date: event.date.to_date)
    assert metric, "PG DailyProjectMetric should be created despite CH failure"
    assert metric.revenue > 0, "Revenue should be recorded in PG"

    assert_equal 0, ch_purchase_count(@project.id), "CH has nothing yet — the batch is parked"
    dlq_len = REDIS.with { |c| c.llen(ClickhouseWriteService::PURCHASE_DLQ_KEY) }
    assert_equal 1, dlq_len, "failed purchase CH write must be parked in the DLQ, not dropped"
  ensure
    REDIS.with { |c| c.del(ClickhouseWriteService::PURCHASE_DLQ_KEY) }
  end

  test "draining the purchase DLQ replays the parked purchase into CH" do
    event = create_unprocessed_event(transaction_id: "txn_drain_test")
    REDIS.with { |c| c.del(ClickhouseWriteService::PURCHASE_DLQ_KEY) }

    ClickhouseWriteService.stub(:raw_insert, ->(_t, _r) { raise StandardError, "CH down" }) do
      @job.perform(event.id)
    end
    assert_equal 0, ch_purchase_count(@project.id), "parked, not yet in CH"

    drained = ClickhouseWriteService.drain_purchase_dlq
    assert_equal 1, drained, "drain must replay the parked batch"
    assert_equal 1, ch_purchase_count(@project.id), "the purchase is now durably in CH"
  ensure
    REDIS.with { |c| c.del(ClickhouseWriteService::PURCHASE_DLQ_KEY) }
  end

  test "no CH write when clickhouse_write_enabled is false" do
    Rails.application.config.clickhouse_write_enabled = false
    event = create_unprocessed_event

    # If ClickhouseWriteService.insert_purchase_events were called, it would
    # early-return true (Clickhouse.enabled? == false). Verify no row.
    @job.perform(event.id)

    event.reload
    assert event.processed?
    assert_equal 0, ch_purchase_count(@project.id)
  end

  test "already processed event re-emits its CH row without touching the ledger" do
    event = purchase_events(:buy_event)
    assert event.processed?
    assert_nil event.accounted_usd_price_cents, "Precondition: legacy null baseline"
    revenue_before = pg_revenue(@project)

    @job.perform(event.id)

    rows = ch_purchase_rows(@project.id, extra_where: "transaction_id = '#{event.transaction_id}'")
    assert_equal 1, rows.size
    assert_equal event.usd_price_cents, rows.first["usd_price_cents"]
    assert_nil event.reload.accounted_usd_price_cents, "a null baseline is never treated as drift"
    assert_equal revenue_before, pg_revenue(@project)
  end

  test "Apple and Google purchases produce distinct CH rows" do
    apple_event = create_unprocessed_event(
      store_source: Grovs::Webhooks::APPLE,
      device: devices(:ios_device),
      transaction_id: "txn_apple_distinct"
    )
    google_event = create_unprocessed_event(
      store_source: Grovs::Webhooks::GOOGLE,
      device: devices(:android_device),
      purchase_type: Grovs::Purchases::TYPE_ONE_TIME,
      transaction_id: "txn_google_distinct"
    )

    @job.perform(apple_event.id)
    @job.perform(google_event.id)

    assert_equal 2, ch_purchase_count(@project.id)

    apple_row = ch_purchase_rows(@project.id, extra_where: "transaction_id = 'txn_apple_distinct'").first
    google_row = ch_purchase_rows(@project.id, extra_where: "transaction_id = 'txn_google_distinct'").first

    assert_equal "apple", apple_row["store_source"]
    assert_equal devices(:ios_device).id, apple_row["device_id"]

    assert_equal "google", google_row["store_source"]
    assert_equal devices(:android_device).id, google_row["device_id"]
    assert_equal "one_time", google_row["purchase_type"]
  end

  test "duplicate CH insert deduplicates via ReplacingMergeTree" do
    event = create_unprocessed_event

    @job.perform(event.id)

    # Manually insert the same row again (simulating crash-recovery replay)
    row = ch_purchase_rows(@project.id, extra_where: "transaction_id = '#{event.transaction_id}'").first
    assert_not_nil row, "First insert must succeed"

    # Re-insert same data with same ORDER BY key (project_id, transaction_id, event_type)
    ClickhouseWriteService.insert_purchase_events([{
      project_id: row["project_id"], event_type: row["event_type"],
      purchase_type: row["purchase_type"], product_id: row["product_id"],
      usd_price_cents: row["usd_price_cents"], currency: row["currency"],
      quantity: row["quantity"], transaction_id: row["transaction_id"],
      original_transaction_id: row["original_transaction_id"],
      store_source: row["store_source"], device_id: row["device_id"],
      link_id: row["link_id"], visitor_id: row["visitor_id"],
      purchase_date: event.date, created_at: event.created_at
    }])

    # Without FINAL we may see 2 rows; with FINAL, ReplacingMergeTree collapses them
    Clickhouse.with { |conn| conn.execute("OPTIMIZE TABLE purchase_events FINAL") }

    count = Clickhouse.with do |conn|
      conn.select_value(
        "SELECT COUNT(*) FROM purchase_events FINAL " \
        "WHERE project_id = #{@project.id} AND transaction_id = '#{event.transaction_id}'"
      )
    end
    assert_equal 1, count, "ReplacingMergeTree must collapse duplicate on (project_id, transaction_id, event_type)"
  end

  test "purchase_project_daily MV populated with correct aggregates" do
    event = create_unprocessed_event(
      date: Time.utc(2026, 4, 15, 10, 0, 0),
      usd_price_cents: 1500,
      store_source: Grovs::Webhooks::APPLE
    )

    @job.perform(event.id)

    rows = ch_rollup_rows('purchase_project_daily',
                          "event_date = '2026-04-15' AND store_source = 'apple' AND event_type = '#{Grovs::Purchases::EVENT_BUY}'")
    assert_equal 1, rows.size, "purchase_project_daily should have one row"
    assert_equal 1500, rows.first["total_revenue_cents"]
    assert_equal 1, rows.first["units"]
  end

  test "purchase_product_daily MV populated with correct aggregates" do
    event = create_unprocessed_event(
      date: Time.utc(2026, 4, 15, 10, 0, 0),
      product_id: "com.test.mv_check",
      usd_price_cents: 2000,
      store_source: Grovs::Webhooks::GOOGLE
    )

    @job.perform(event.id)

    rows = ch_rollup_rows('purchase_product_daily',
                          "product_id = 'com.test.mv_check' AND event_type = '#{Grovs::Purchases::EVENT_BUY}'")
    assert_equal 1, rows.size, "purchase_product_daily should have one row"
    assert_equal 2000, rows.first["total_revenue_cents"]
    assert_equal 1, rows.first["units"]
    assert_equal "google", rows.first["store_source"]
  end

  test "multiple purchases aggregate correctly in purchase_product_daily MV" do
    3.times do |i|
      event = create_unprocessed_event(
        date: Time.utc(2026, 4, 20, 10, 0, 0),
        product_id: "com.test.multi_agg",
        usd_price_cents: 500,
        store_source: Grovs::Webhooks::APPLE,
        transaction_id: "txn_multi_#{i}"
      )
      @job.perform(event.id)
    end

    Clickhouse.with { |conn| conn.execute("OPTIMIZE TABLE purchase_product_daily FINAL") }

    rows = ch_rollup_rows('purchase_product_daily', "product_id = 'com.test.multi_agg' AND event_date = '2026-04-20'")
    total_revenue = rows.sum { |r| r["total_revenue_cents"] }
    total_units = rows.sum { |r| r["units"] }

    assert_equal 1500, total_revenue, "3 x 500 = 1500 total revenue"
    assert_equal 3, total_units, "3 purchases = 3 units"
  end

  def ch_purchase_price(event)
    Clickhouse.with { |c| c.execute("OPTIMIZE TABLE purchase_events FINAL") }
    Clickhouse.with do |c|
      c.select_value(
        "SELECT usd_price_cents FROM purchase_events FINAL " \
        "WHERE project_id = #{@project.id} AND transaction_id = '#{event.transaction_id}'"
      ).to_i
    end
  end

  def ch_rollup_revenue(event)
    Clickhouse.with do |c|
      c.select_value(
        "SELECT sum(total_revenue_cents) FROM purchase_project_daily FINAL " \
        "WHERE project_id = #{@project.id} AND transaction_id = '#{event.transaction_id}'"
      ).to_i
    end
  end

  # Seed CH at the OLD price, correct to a NEW price, and assert CH TRANSITIONS.
  # Starting at the target price would pass even if apply_correction never wrote.
  test "apply_correction writes the corrected row to CH" do
    event = create_unprocessed_event(usd_price_cents: 999, price_cents: 999)
    @job.perform(event.id) # CH now holds the original 999
    assert_equal 999, ch_purchase_price(event), "precondition: CH seeded at old price"

    event.update!(usd_price_cents: 1499, price_cents: 1499) # price corrected in PG
    @job.perform(event.id, 999) # correction: old=999

    assert_equal 1499, ch_purchase_price(event),
                 "correction must re-insert the corrected price (would stay 999 if it didn't write)"
  end

  test "apply_correction converges the signed project rollup" do
    event = create_unprocessed_event(usd_price_cents: 999, price_cents: 999)
    @job.perform(event.id)
    assert_equal 999, ch_rollup_revenue(event), "precondition: rollup seeded at old price"

    event.update!(usd_price_cents: 1499, price_cents: 1499)
    @job.perform(event.id, 999)

    assert_equal 1499, ch_rollup_revenue(event),
                 "rollup must converge to the corrected price (would stay 999 if it didn't write)"
  end

  test "CH row carries recorded_at (PG created_at) and the ledger platform" do
    event = create_unprocessed_event(device: devices(:ios_device), store_source: Grovs::Webhooks::GOOGLE)
    @job.perform(event.id)

    row = ch_purchase_rows(@project.id, extra_where: "transaction_id = '#{event.transaction_id}'").first
    assert_in_delta event.created_at.to_f, ch_time(row["recorded_at"]).to_f, 0.001
    assert_equal event.reload.revenue_platform, row["platform"]
    assert_equal "android", row["platform"]
  end

  test "recorded_at survives a price correction while the version moves" do
    event = create_unprocessed_event(device: devices(:ios_device))
    @job.perform(event.id)
    event.update_columns(usd_price_cents: 1299)
    @job.perform(event.id, 999)

    rows = Clickhouse.with do |c|
      c.select_all("SELECT recorded_at, created_at FROM purchase_events FINAL WHERE project_id = #{@project.id} " \
                   "AND transaction_id = '#{event.transaction_id}'").to_a
    end
    assert_equal 1, rows.size
    assert_in_delta event.created_at.to_f, ch_time(rows.first["recorded_at"]).to_f, 0.001
    assert_operator ch_time(rows.first["created_at"]), :>, ch_time(rows.first["recorded_at"])
  end

  test "price drift on a processed row runs the correction and emits the accounted price" do
    event = create_unprocessed_event(device: devices(:ios_device), usd_price_cents: 999, price_cents: 999)
    @job.perform(event.id)
    assert_equal 999, event.reload.accounted_usd_price_cents
    pg_before = pg_revenue(@project)

    event.update_columns(usd_price_cents: 1299, price_cents: 1299)
    @job.perform(event.id)

    assert_equal 1299, event.reload.accounted_usd_price_cents
    row = latest_ch_row(event)
    assert_equal 1299, row["usd_price_cents"]
    assert_equal 1299, ch_rollup_revenue(event)
    assert_equal 300, pg_revenue(@project) - pg_before, "the PG ledger moved by exactly the delta"
  end

  test "a refresh during an un-accounted price rewrite publishes the accounted price" do
    event = create_unprocessed_event(device: devices(:ios_device), usd_price_cents: 999, price_cents: 999)
    @job.perform(event.id)
    event.update_columns(usd_price_cents: 1299)

    ProcessPurchaseEventJob.dual_write_clickhouse(event)

    assert_equal 999, latest_ch_row(event)["usd_price_cents"]
  end

  test "a zero-delta correction on a subscription cancel still re-emits" do
    event = purchase_events(:cancel_event)
    assert event.processed?
    event.update_columns(product_id: "com.test.renamed", usd_price_cents: 777, price_cents: 777)

    @job.perform(event.id, event.usd_price_cents.to_i)

    row = latest_ch_row(event)
    assert_equal "com.test.renamed", row["product_id"]
    assert_equal 777, row["usd_price_cents"], "accounted is set even when the delta is zero"
    assert_equal 777, event.reload.accounted_usd_price_cents
  end

  test "dual_write builds from a fresh reload so a stale object cannot win" do
    event = create_unprocessed_event(device: devices(:ios_device))
    @job.perform(event.id)
    stale = PurchaseEvent.includes(:device).find(event.id)
    PurchaseEvent.where(id: event.id).update_all(session_id: "sess-late")

    ProcessPurchaseEventJob.dual_write_clickhouse(stale)

    assert_equal "sess-late", latest_ch_row(event)["session_id"]
  end

  test "each emit carries a strictly newer version and FINAL keeps the last one" do
    event = create_unprocessed_event(device: devices(:ios_device))
    t0 = Time.current.change(usec: 0)
    travel_to(t0) { @job.perform(event.id) }
    first = latest_ch_row(event)["created_at"]
    event.update_columns(usd_price_cents: 1299, price_cents: 1299)
    travel_to(t0 + 1.second) { @job.perform(event.id) }
    PurchaseEvent.where(id: event.id).update_all(session_id: "after-correction")
    travel_to(t0 + 2.seconds) { @job.perform(event.id) }

    row = latest_ch_row(event)
    assert_operator ch_time(row["created_at"]), :>, ch_time(first)
    assert_equal "after-correction", row["session_id"]
    assert_equal 1299, row["usd_price_cents"]
    assert_equal 1, ch_final_count(event), "FINAL collapses the three versions to the newest"
  end

  test "a price change between load and claim is accounted exactly once" do
    event = create_unprocessed_event(device: devices(:ios_device), usd_price_cents: 100, price_cents: 100)
    pg_before = pg_revenue(@project)
    @job.stub(:retry_currency_conversion!, ->(e) { PurchaseEvent.where(id: e.id).update_all(usd_price_cents: 200, price_cents: 200) }) do
      @job.perform(event.id)
    end
    assert_equal 200, event.reload.accounted_usd_price_cents, "claim reads the price it locks, not the cached one"
    assert_equal 200, pg_revenue(@project) - pg_before

    @job.perform(event.id)
    assert_equal 200, pg_revenue(@project) - pg_before
    assert_equal 200, latest_ch_row(event)["usd_price_cents"]
  end

  test "a correction landing in a later month still leaves one row under FINAL" do
    event = create_unprocessed_event(device: devices(:ios_device), usd_price_cents: 999, price_cents: 999)
    @job.perform(event.id)
    event.update_columns(usd_price_cents: 1299, price_cents: 1299)

    travel_to(Time.current + 40.days) { @job.perform(event.id) }

    assert_equal 1, ch_final_count(event)
    assert_equal 1299, latest_ch_row(event)["usd_price_cents"]
    months = Clickhouse.with do |c|
      c.select_value("SELECT uniqExact(toYYYYMM(created_at)) FROM purchase_events " \
                     "WHERE project_id = #{@project.id} AND transaction_id = '#{event.transaction_id}'")
    end
    assert_equal 2, months.to_i, "the two versions really are in different partitions"

    PurchaseEvent.where(id: event.id).update_all(session_id: "after-cross-month")
    travel_to(Time.current + 41.days) { @job.perform(event.id) } # plain refresh, no drift

    assert_equal 1, ch_final_count(event)
    assert_equal "after-cross-month", latest_ch_row(event)["session_id"], "refresh outranks the later-month correction"
  end

  test "a stale DLQ replay cannot overwrite a newer live emit" do
    event = create_unprocessed_event(device: devices(:ios_device))
    ClickhouseWriteService.stub(:raw_insert, ->(*) { raise "ch down" }) do
      @job.perform(event.id)
    end
    PurchaseEvent.where(id: event.id).update_all(session_id: "live-after-outage")
    ProcessPurchaseEventJob.dual_write_clickhouse(event)

    ClickhouseWriteService.drain_purchase_dlq

    assert_equal "live-after-outage", latest_ch_row(event)["session_id"]
  end

  test "a purchase moved to another project before the claim is processed under the new project" do
    event = create_unprocessed_event(device: devices(:ios_device), usd_price_cents: 500, price_cents: 500)
    target = projects(:one_test)
    before = pg_revenue(target)
    @job.stub(:retry_currency_conversion!, ->(e) { PurchaseEvent.where(id: e.id).update_all(project_id: target.id) }) do
      @job.perform(event.id)
    end
    assert_equal 500, pg_revenue(target) - before, "aggregates land under the project the claim locked"
    assert_equal target.id, latest_ch_row(event.reload)["project_id"]
  end

  test "a PG failure on the reload raises so Sidekiq retries" do
    event = create_unprocessed_event(device: devices(:ios_device))
    PurchaseEvent.stub(:includes, ->(*) { raise ActiveRecord::StatementInvalid, "pg down" }) do
      assert_raises(ActiveRecord::StatementInvalid) { ProcessPurchaseEventJob.dual_write_clickhouse(event) }
    end
  end

  test "a redelivery for a purchase deleted meanwhile does nothing" do
    event = purchase_events(:buy_event)
    id = event.id
    PurchaseEvent.where(id: id).delete_all
    assert_nothing_raised { @job.perform(id) }
    assert_equal 0, ch_purchase_rows(@project.id, extra_where: "transaction_id = '#{event.transaction_id}'").size
  end

  test "sync path makes no currency call on a processed row with a nil usd price" do
    event = purchase_events(:nil_usd_buy)
    event.update_columns(processed: true, usd_price_cents: nil, accounted_usd_price_cents: nil)
    CurrencyConversionService.stub(:to_usd_cents, ->(*) { flunk "must not convert on the sync path" }) do
      @job.perform(event.id)
    end
    assert_equal 1, ch_purchase_rows(@project.id, extra_where: "transaction_id = '#{event.transaction_id}'").size
  end

  test "reattribution after a correction lands the visitor in the CH row and the explorer" do
    event = create_unprocessed_event(device: nil, usd_price_cents: 999, price_cents: 999)
    @job.perform(event.id)
    assert_nil event.reload.visitor_id, "processed deviceless: no visitor snapshot yet"
    event.update_columns(usd_price_cents: 1299, price_cents: 1299)
    @job.perform(event.id) # drift -> correction
    event.update_columns(device_id: devices(:ios_device).id, session_id: "sess-late")

    inline = ->(id, *args) { ProcessPurchaseEventJob.new.perform(id, *args) }
    ProcessPurchaseEventJob.stub(:perform_async, inline) { ReattributePurchaseJob.new.perform(event.id) }

    visitor = devices(:ios_device).visitor_for_project_id(@project.id)
    row = latest_ch_row(event)
    assert_equal visitor.id, row["visitor_id"]
    assert_equal "sess-late", row["session_id"]
    assert_equal 1299, row["usd_price_cents"]
    assert_in_delta event.created_at.to_f, ch_time(row["recorded_at"]).to_f, 0.001, "timeline position is unchanged"
    assert_operator ch_time(row["created_at"]), :>, ch_time(row["recorded_at"]), "version moved, recorded time did not"
    shown = Clickhouse.stub(:read_enabled?, true) do
      Analytics::EventsQueryService.find(@project.id, event_id: Analytics::EventsSource.purchase_event_id(event.transaction_id, event.event_type))
    end
    assert_equal visitor.id, shown["visitor_id"], "the explorer shows the post-reattribution visitor"
    assert_equal "sess-late", shown["session_id"]
    assert_in_delta event.created_at.to_f, Time.parse(shown["created_at"].to_s).to_f, 1.0, "explorer sorts it at the recorded time"
  end

  test "an SDK price re-report on a processed purchase corrects PG and CH by the same delta" do
    device = devices(:ios_device)
    service = SdkPaymentService.new(project: @project, device: device, visitor: device.visitor_for_project_id(@project.id),
                                    platform: "ios", identifier: "com.test.app")
    params = lambda do |price|
      ActionController::Parameters.new(
        event_type: Grovs::Purchases::EVENT_BUY, price_cents: price, currency: "USD", store: false,
        transaction_id: "txn_sdk_drift", original_transaction_id: "orig_sdk_drift",
        product_id: "com.test.premium", purchase_type: Grovs::Purchases::TYPE_ONE_TIME
      ).permit!
    end
    inline = ->(id, *args) { ProcessPurchaseEventJob.new.perform(id, *args) }

    ProcessPurchaseEventJob.stub(:perform_async, inline) { service.create_or_update(event_params: params.call(999)) }
    event = PurchaseEvent.find_by!(transaction_id: "txn_sdk_drift")
    assert event.processed?
    pg_before = pg_revenue(@project)

    ProcessPurchaseEventJob.stub(:perform_async, inline) { service.create_or_update(event_params: params.call(1299)) }

    assert_equal 1299, event.reload.accounted_usd_price_cents
    assert_equal 300, pg_revenue(@project) - pg_before
    assert_equal 1299, ch_rollup_revenue(event)
    assert_equal 1299, latest_ch_row(event)["usd_price_cents"]
  end

end
