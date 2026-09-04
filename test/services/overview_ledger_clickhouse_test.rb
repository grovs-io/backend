# frozen_string_literal: true

require "test_helper"

# Ledger branch of Analytics::OverviewStatsService (REVENUE_READS_FROM_LEDGER):
# key_metrics revenue set, ARPPU gate, user_trends daily revenue, cache keys.
class OverviewLedgerClickhouseTest < ActiveSupport::TestCase
  include ClickhouseTestHelper
  include ActiveSupport::Testing::TimeHelpers

  fixtures :instances, :projects, :devices, :visitors

  START_DAY = Date.new(2026, 5, 10)
  END_DAY = Date.new(2026, 5, 11)
  PREV_DAY = Date.new(2026, 5, 9)

  setup do
    skip_unless_clickhouse!
    truncate_clickhouse_tables
    @project = projects(:one)
    PurchaseEvent.delete_all
    DailyProjectMetric.where(project_id: @project.id).delete_all
    @original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new # test env null_store would make cache tests vacuous

    @original_read = Rails.application.config.clickhouse_read_enabled
    @original_flag = Rails.application.config.revenue_reads_from_ledger
    Rails.application.config.clickhouse_read_enabled = true
    Rails.application.config.revenue_reads_from_ledger = true

    # Stat rows say 111/70; the ledger says 500 (current) and 200 (previous span).
    DailyProjectMetric.create!(project_id: @project.id, platform: "ios", event_date: START_DAY,
                               revenue: 111, units_sold: 1, cancellations: 0, first_time_purchases: 9)
    DailyProjectMetric.create!(project_id: @project.id, platform: "ios", event_date: PREV_DAY, revenue: 70)
    ledger_row(usd: 500, device: devices(:ios_device), day: START_DAY)
    ledger_row(usd: 200, device: devices(:android_device), day: PREV_DAY, platform: "android")
    # Unprocessed third device: excluded from revenue AND the ARPPU denominator.
    ledger_row(usd: 999, device: devices(:web_device), day: START_DAY, processed: false)
  end

  teardown do
    Rails.application.config.clickhouse_read_enabled = @original_read
    Rails.application.config.revenue_reads_from_ledger = @original_flag
    Rails.cache = @original_cache
  end

  test "key_metrics serves the ledger revenue set with a processed-gated ARPPU" do
    metrics = key_metrics

    assert_equal 500, metrics[:revenue], "ledger-sourced (stat says 111)"
    assert_equal 1, metrics[:units_sold]
    assert_equal 1, metrics[:first_time_purchases], "event-time earliest buy (stat says 9)"
    assert_equal 500.0, metrics[:arppu], "one processed paying device; unprocessed excluded"
    assert_not metrics.key?(:ledger_degraded), "internal flag never leaks to the response"
  end

  test "user_trends daily revenue comes from the ledger for current AND previous spans" do
    assert_equal 500, trends_point(START_DAY)[:revenue_usd_cents], "ledger-sourced (stat says 111)"
    # PREV_DAY (05-09) is offset 1 in the previous span → maps onto the 05-11 point.
    assert_equal 200, trends_point(END_DAY)[:previous_revenue_usd_cents],
                 "prev-span offset maps ledger, not stat (70)"
  end

  test "user_trends ledger failure caches briefly, then recovery serves the ledger" do
    RevenueLedgerQuery.stub(:daily_series, nil) do
      assert_equal 111, trends_point(START_DAY)[:revenue_usd_cents], "stat fallback"
    end
    assert_equal 111, trends_point(START_DAY)[:revenue_usd_cents], "stampede guard coalesces briefly"

    travel(RevenueLedger::DEGRADED_CACHE_TTL + 1.second) do
      assert_equal 500, trends_point(START_DAY)[:revenue_usd_cents],
                   "recovery is never masked beyond the degraded TTL"
    end
  end

  test "flag flips bypass the cache via the revenue_source key component" do
    Rails.application.config.revenue_reads_from_ledger = false
    assert_equal 111, key_metrics[:revenue], "stat mode cached under the st key"

    Rails.application.config.revenue_reads_from_ledger = true
    assert_equal 500, key_metrics[:revenue], "ledger mode reads its own key, not the stat cache"
  end

  private

  def key_metrics
    Analytics::OverviewStatsService.key_metrics(
      @project.id, start_date: START_DAY.to_s, end_date: END_DAY.to_s
    )[:metrics]
  end

  def trends_point(day)
    result = Analytics::OverviewStatsService.user_trends(
      @project.id, start_date: START_DAY.to_s, end_date: END_DAY.to_s, cutoff: Date.new(2026, 4, 1)
    )
    result[:points].find { |p| p[:date] == day.strftime("%Y-%m-%d") } ||
      result[:points].find { |p| p["date"] == day.strftime("%Y-%m-%d") }
  end

  def ledger_row(usd:, device:, day:, platform: "ios", processed: true)
    pe = PurchaseEvent.create!(
      project: @project, event_type: "buy", usd_price_cents: usd, quantity: 1,
      device: device, product_id: "com.test.p", purchase_type: "one_time", processed: processed,
      date: day.to_time.change(hour: 12), transaction_id: "olc_#{SecureRandom.hex(5)}"
    )
    pe.update_columns(revenue_platform: platform,
                      visitor_id: Visitor.find_by(device_id: device.id, project_id: @project.id)&.id)
    pe
  end
end
