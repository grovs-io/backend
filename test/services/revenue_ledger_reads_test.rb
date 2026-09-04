# frozen_string_literal: true

require "test_helper"

# REVENUE_READS_FROM_LEDGER on the PG-only surfaces; ledger and stat values differ
# so each number's source is provable.
class RevenueLedgerReadsTest < ActiveSupport::TestCase
  include ActiveSupport::Testing::TimeHelpers

  fixtures :instances, :projects, :devices, :visitors

  RANGE_START = Date.new(2026, 5, 10)
  RANGE_END = Date.new(2026, 5, 11)

  setup do
    @project = projects(:one)
    PurchaseEvent.delete_all
    DailyProjectMetric.where(project_id: @project.id).delete_all
    @original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new # test env null_store would make cache tests vacuous

    @original_flag = Rails.application.config.revenue_reads_from_ledger
    Rails.application.config.revenue_reads_from_ledger = true

    # Stat table says one thing…
    DailyProjectMetric.create!(project_id: @project.id, platform: "ios", event_date: RANGE_START,
                               revenue: 111, units_sold: 1, cancellations: 1, first_time_purchases: 9)
    # …the ledger says another.
    ledger_row(usd: 500, device: devices(:ios_device), platform: "ios")
    ledger_row(usd: 200, qty: 2, device: devices(:android_device), platform: "android")
    ledger_row(event_type: "cancel", purchase_type: "one_time", usd: 100,
               device: devices(:ios_device), platform: "ios")
    # Unprocessed on a third device: excluded from revenue AND from the ARPPU denominator.
    ledger_row(usd: 999, device: devices(:web_device), platform: "ios", processed: false)
  end

  teardown do
    Rails.application.config.revenue_reads_from_ledger = @original_flag
    Rails.cache = @original_cache
  end

  test "dashboard totals come from the ledger, not daily_project_metrics" do
    metrics = DashboardMetrics.call(project_id: @project.id, start_time: RANGE_START, end_time: RANGE_END)[:current]

    assert_equal 800, metrics[:revenue], "500 + 400 - 100 from the ledger (stat says 111)"
    assert_equal 3, metrics[:units_sold]
    assert_equal 1, metrics[:cancellations]
    assert_equal 400.0, metrics[:arppu], "denominator = processed paying devices (2), unprocessed excluded"
  end

  test "dashboard platform filter uses revenue_platform snapshots" do
    metrics = DashboardMetrics.call(project_id: @project.id, start_time: RANGE_START,
                                    end_time: RANGE_END, platform: "android")[:current]

    assert_equal 400, metrics[:revenue]
  end

  test "dashboard first_time_purchases derives from event-time earliest buys" do
    metrics = DashboardMetrics.call(project_id: @project.id, start_time: RANGE_START, end_time: RANGE_END)[:current]

    # Two devices, each first-ever buy inside the range (stat column says 9).
    assert_equal 2, metrics[:first_time_purchases]
  end

  test "flag off keeps stat-table values" do
    Rails.application.config.revenue_reads_from_ledger = false

    metrics = DashboardMetrics.call(project_id: @project.id, start_time: RANGE_START, end_time: RANGE_END)[:current]

    assert_equal 111, metrics[:revenue]
    assert_equal 9, metrics[:first_time_purchases]
  end

  test "ledger failure falls back to stat values AND the legacy ARPPU population" do
    RevenueLedgerQuery.stub(:project_totals, nil) do
      RevenueLedgerQuery.stub(:first_time_purchases, nil) do
        metrics = DashboardMetrics.call(project_id: @project.id, start_time: RANGE_START, end_time: RANGE_END)[:current]

        assert_equal 111, metrics[:revenue]
        # Legacy gate counts the unprocessed store=false row's device too → 3 devices.
        assert_equal (111 / 3.0).round(2), metrics[:arppu], "numerator and denominator from the SAME population"
      end
    end
  end

  test "partial ledger failure keeps ALL purchase metrics stat-sourced (all-or-nothing)" do
    RevenueLedgerQuery.stub(:first_time_purchases, nil) do
      metrics = DashboardMetrics.call(project_id: @project.id, start_time: RANGE_START, end_time: RANGE_END)[:current]

      assert_equal 111, metrics[:revenue], "totals revert too, never a ledger/stat mix"
      assert_equal 9, metrics[:first_time_purchases]
    end
  end

  test "degraded responses cache only briefly, then recovery serves the ledger" do
    RevenueLedgerQuery.stub(:project_totals, nil) do
      degraded = DashboardMetrics.call(project_id: @project.id, start_time: RANGE_START, end_time: RANGE_END)[:current]
      assert_equal 111, degraded[:revenue], "transient failure serves stat values"
    end

    within_ttl = DashboardMetrics.call(project_id: @project.id, start_time: RANGE_START, end_time: RANGE_END)[:current]
    assert_equal 111, within_ttl[:revenue], "stampede guard: degraded result coalesces briefly"

    travel(RevenueLedger::DEGRADED_CACHE_TTL + 1.second) do
      healthy = DashboardMetrics.call(project_id: @project.id, start_time: RANGE_START, end_time: RANGE_END)[:current]
      assert_equal 800, healthy[:revenue], "recovery is never masked beyond the degraded TTL"
    end
  end

  test "referral overlay swaps invited_revenue to the ledger, keeps other columns" do
    inviter = visitors(:ios_visitor)
    invited = visitors(:android_visitor)
    invited.update!(inviter_id: inviter.id)
    VisitorDailyStatistic.where(project_id: @project.id).delete_all
    VisitorDailyStatistic.create!(visitor: inviter, project_id: @project.id, event_date: RANGE_START,
                                  platform: "ios", views: 7, invited_by_id: nil)
    # Stat says invited revenue 5; ledger attributes android_visitor's 400 to the inviter.
    VisitorDailyStatistic.create!(visitor: invited, project_id: @project.id, event_date: RANGE_START,
                                  platform: "android", revenue: 5, invited_by_id: inviter.id)
    PurchaseEvent.where(device_id: devices(:android_device).id)
                 .update_all(visitor_id: invited.id)

    result = VisitorReferralStatisticsQuery.new(
      params: { start_date: RANGE_START, end_date: RANGE_END, visitor_id: inviter.id },
      project: @project
    ).call
    row = result[:visitors].first

    assert_equal 400, row["invited_revenue"], "ledger-sourced (stat says 5)"
  end

  private

  def ledger_row(usd:, device:, platform:, event_type: "buy", qty: 1,
                 purchase_type: "one_time", processed: true)
    pe = PurchaseEvent.create!(
      project: @project, event_type: event_type, usd_price_cents: usd, quantity: qty,
      device: device, product_id: "com.test.p", purchase_type: purchase_type, processed: processed,
      date: RANGE_START.to_time.change(hour: 12), transaction_id: "rlr_#{SecureRandom.hex(5)}"
    )
    pe.update_columns(revenue_platform: platform,
                      visitor_id: device && Visitor.find_by(device_id: device.id, project_id: @project.id)&.id)
    pe
  end
end
