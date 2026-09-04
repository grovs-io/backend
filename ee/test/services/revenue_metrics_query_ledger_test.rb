# frozen_string_literal: true

require "test_helper"

# Ledger path of RevenueMetricsQuery (REVENUE_READS_FROM_LEDGER).
class RevenueMetricsQueryLedgerTest < ActiveSupport::TestCase
  fixtures :instances, :projects, :devices

  RANGE_START = Date.new(2026, 5, 10)
  RANGE_END = Date.new(2026, 5, 12)

  setup do
    @project = projects(:one)
    PurchaseEvent.delete_all
    @original_flag = Rails.application.config.revenue_reads_from_ledger
    Rails.application.config.revenue_reads_from_ledger = true

    d1 = devices(:ios_device)
    d2 = devices(:android_device)
    # Product A: two first-time buys, one repeat, one refund.
    ledger_row(product: "com.a", usd: 500, device: d1, platform: "ios", day: 10)
    ledger_row(product: "com.a", usd: 300, device: d1, platform: "ios", day: 11)
    ledger_row(product: "com.a", usd: 200, device: d2, platform: "android", day: 11)
    ledger_row(product: "com.a", usd: 100, device: d1, platform: "ios", day: 12, event_type: "refund")
    # Product B: single buy; plus an unprocessed row that must not count.
    ledger_row(product: "com.b", usd: 50, device: d2, platform: "android", day: 10)
    ledger_row(product: "com.b", usd: 999, device: d2, platform: "android", day: 10, processed: false)
  end

  teardown { Rails.application.config.revenue_reads_from_ledger = @original_flag }

  test "aggregates products from the ledger with event-time first/repeat" do
    rows = query.call.index_by { |r| r["product_id"] }
    a = rows["com.a"]

    assert_equal 900, a["total_revenue_usd_cents"].to_i
    assert_equal 3, a["units_sold"].to_i
    assert_equal 1, a["cancellations"].to_i, "one_time refund counts as cancellation"
    assert_equal 2, a["first_time_purchases"].to_i, "earliest buy per device"
    assert_equal 1, a["repeat_purchases"].to_i
    assert_equal 2, a["unique_purchasers"].to_i
    assert_equal 450.0, a["ltv_usd_cents"].to_f, "all-time device revenue / purchasing devices"
    assert_equal %w[android ios], JSON.parse(a["platforms"]).sort
    assert_equal 50, rows["com.b"]["total_revenue_usd_cents"].to_i, "unprocessed row excluded"
  end

  test "sorts and paginates in Ruby with stable total count" do
    page1 = query(sort_by: "total_revenue_usd_cents", ascendent: false).call(page: 1, per_page: 1)
    page2 = query(sort_by: "total_revenue_usd_cents", ascendent: false).call(page: 2, per_page: 1)

    assert_equal "com.a", page1.first["product_id"]
    assert_equal "com.b", page2.first["product_id"]
    assert_equal 2, page1.total_count
    assert_equal 2, page1.total_pages
  end

  test "platform and product filters apply on the ledger path" do
    android_only = query(platform: "android").call.index_by { |r| r["product_id"] }

    assert_equal 200, android_only["com.a"]["total_revenue_usd_cents"].to_i
    assert_equal ["android"], JSON.parse(android_only["com.a"]["platforms"])

    filtered = query(product: "com.b").call
    assert_equal ["com.b"], filtered.map { |r| r["product_id"] }
  end

  test "platforms only include platforms with reportable activity" do
    # Nil-priced SUBSCRIPTION refund: no revenue, no units, not a cancellation.
    pe = PurchaseEvent.create!(
      project: @project, event_type: "refund", usd_price_cents: nil, quantity: 1,
      device: devices(:ios_device), product_id: "com.a", purchase_type: "subscription",
      processed: true, date: Time.utc(2026, 5, 11, 12), transaction_id: "rmql_#{SecureRandom.hex(5)}"
    )
    pe.update_columns(revenue_platform: "web")

    a = query.call.find { |r| r["product_id"] == "com.a" }

    assert_not_includes JSON.parse(a["platforms"]), "web"
  end

  test "equal-value products tie-break by product_id ascending in both directions" do
    ledger_row(product: "com.z", usd: 50, device: devices(:ios_device), platform: "ios", day: 10) # ties com.b

    desc = query(sort_by: "total_revenue_usd_cents", ascendent: false).call.map { |r| r["product_id"] }
    asc = query(sort_by: "total_revenue_usd_cents", ascendent: true).call.map { |r| r["product_id"] }

    assert_equal %w[com.b com.z], desc.last(2)
    assert_equal %w[com.b com.z], asc.first(2)
  end

  test "ledger failure falls back to the legacy query" do
    RevenueLedgerQuery.stub(:product_totals, nil) do
      assert_nothing_raised { query.call }
    end
  end

  test "with_arpu decorates ledger rows" do
    VisitorDailyStatistic.where(project_id: @project.id).delete_all
    VisitorDailyStatistic.create!(visitor: visitors_fixture, project_id: @project.id,
                                  event_date: RANGE_START, platform: "ios", views: 1)

    rows = query.with_arpu.index_by { |r| r["product_id"] }

    assert_equal 900.0, rows["com.a"]["arpu_usd_cents"], "revenue / 1 distinct visitor"
    assert_equal 450.0, rows["com.a"]["arppu_usd_cents"], "revenue / 2 unique purchasers"
  end

  private

  def visitors_fixture
    Visitor.find_by(device_id: devices(:ios_device).id, project_id: @project.id) ||
      Visitor.create!(project: @project, device: devices(:ios_device), web_visitor: false,
                      sdk_identifier: "rmq_ledger", uuid: SecureRandom.uuid)
  end

  def query(platform: nil, product: nil, sort_by: nil, ascendent: true)
    RevenueMetricsQuery.new(
      project_id: @project.id, start_date: RANGE_START, end_date: RANGE_END,
      product: product, platform: platform, sort_by: sort_by, ascendent: ascendent
    )
  end

  def ledger_row(product:, usd:, device:, platform:, day:, event_type: "buy", processed: true)
    pe = PurchaseEvent.create!(
      project: @project, event_type: event_type, usd_price_cents: usd, quantity: 1,
      device: device, product_id: product, purchase_type: "one_time", processed: processed,
      date: Time.utc(2026, 5, day, 12), transaction_id: "rmql_#{SecureRandom.hex(5)}"
    )
    pe.update_columns(revenue_platform: platform)
    pe
  end
end
