require "test_helper"

class DashboardMetricsTest < ActiveSupport::TestCase
  fixtures :projects, :instances, :devices, :visitors

  setup do
    @project = projects(:one)
    @pid = @project.id

    # Clean up any VDS and PurchaseEvent records from fixtures or prior tests
    VisitorDailyStatistic.where(project_id: @pid).delete_all
    PurchaseEvent.where(project_id: @pid).delete_all

    # ── Current period: Mar 1–2 ──
    # first_time_visitors must match VDS setup: ios_visitor is first-time on Mar 1,
    # no new first-timers on Mar 2 (android_visitor has prior VDS on Feb 20).
    DailyProjectMetric.create!(
      project_id: @pid, event_date: Date.new(2026, 3, 1), platform: "ios",
      views: 100, installs: 10, opens: 50, reinstalls: 2, link_views: 80,
      referred_users: 3, organic_users: 7, new_users: 10, app_opens: 30,
      first_time_visitors: 1, revenue: 1000, units_sold: 5, cancellations: 1,
      first_time_purchases: 3
    )
    DailyProjectMetric.create!(
      project_id: @pid, event_date: Date.new(2026, 3, 2), platform: "ios",
      views: 200, installs: 20, opens: 80, reinstalls: 5, link_views: 150,
      referred_users: 7, organic_users: 13, new_users: 20, app_opens: 60,
      first_time_visitors: 0, revenue: 2000, units_sold: 8, cancellations: 2,
      first_time_purchases: 5
    )

    # ── Previous period: Feb 27–28 (same length = 2 days) ──
    DailyProjectMetric.create!(
      project_id: @pid, event_date: Date.new(2026, 2, 27), platform: "ios",
      views: 50, installs: 5, opens: 25, reinstalls: 1, link_views: 40,
      referred_users: 1, organic_users: 4, new_users: 5, app_opens: 15,
      first_time_visitors: 4, revenue: 500, units_sold: 2, cancellations: 0,
      first_time_purchases: 1
    )
    DailyProjectMetric.create!(
      project_id: @pid, event_date: Date.new(2026, 2, 28), platform: "ios",
      views: 60, installs: 6, opens: 30, reinstalls: 2, link_views: 45,
      referred_users: 2, organic_users: 4, new_users: 6, app_opens: 20,
      first_time_visitors: 5, revenue: 600, units_sold: 3, cancellations: 1,
      first_time_purchases: 2
    )

    # ── VisitorDailyStatistic records ──
    # Visitor A: has records only in Mar 1–2 range → first-time visitor
    @visitor_a = visitors(:ios_visitor)
    VisitorDailyStatistic.create!(
      visitor: @visitor_a, project_id: @pid,
      event_date: Date.new(2026, 3, 1), platform: "ios", views: 10
    )
    VisitorDailyStatistic.create!(
      visitor: @visitor_a, project_id: @pid,
      event_date: Date.new(2026, 3, 2), platform: "ios", views: 15
    )

    # Visitor B: has a record BEFORE Mar 1 → returning visitor
    @visitor_b = visitors(:android_visitor)
    VisitorDailyStatistic.create!(
      visitor: @visitor_b, project_id: @pid,
      event_date: Date.new(2026, 2, 20), platform: "android", views: 5
    )
    VisitorDailyStatistic.create!(
      visitor: @visitor_b, project_id: @pid,
      event_date: Date.new(2026, 3, 1), platform: "android", views: 8
    )

    # ── PurchaseEvent records ──
    # Two paying devices (ios_device, android_device) with BUY events in Mar 1–2
    @ios_device = devices(:ios_device)
    @android_device = devices(:android_device)

    PurchaseEvent.create!(
      event_type: Grovs::Purchases::EVENT_BUY,
      device: @ios_device, project: @project,
      identifier: "com.test.app", price_cents: 999, currency: "USD",
      usd_price_cents: 999, date: DateTime.new(2026, 3, 1, 10, 0, 0),
      transaction_id: "dm_txn_001", original_transaction_id: "dm_orig_001",
      product_id: "com.test.premium", webhook_validated: true, store: true,
      processed: true, purchase_type: "subscription"
    )
    PurchaseEvent.create!(
      event_type: Grovs::Purchases::EVENT_BUY,
      device: @android_device, project: @project,
      identifier: "com.test.app", price_cents: 499, currency: "USD",
      usd_price_cents: 499, date: DateTime.new(2026, 3, 1, 14, 0, 0),
      transaction_id: "dm_txn_002", original_transaction_id: "dm_orig_002",
      product_id: "com.test.onetime", webhook_validated: true, store: true,
      processed: true, purchase_type: "one_time"
    )

    # A cancel event — should NOT count as a paying user
    PurchaseEvent.create!(
      event_type: Grovs::Purchases::EVENT_CANCEL,
      device: @ios_device, project: @project,
      identifier: "com.test.app", price_cents: 999, currency: "USD",
      usd_price_cents: 999, date: DateTime.new(2026, 3, 2, 10, 0, 0),
      transaction_id: "dm_txn_003", original_transaction_id: "dm_orig_001",
      product_id: "com.test.premium", webhook_validated: true, store: true,
      processed: true, purchase_type: "subscription"
    )

    # A buy with no device — should NOT count as a paying user
    PurchaseEvent.create!(
      event_type: Grovs::Purchases::EVENT_BUY,
      device: nil, project: @project,
      identifier: "com.test.app", price_cents: 999, currency: "USD",
      usd_price_cents: 999, date: DateTime.new(2026, 3, 1, 16, 0, 0),
      transaction_id: "dm_txn_004", original_transaction_id: "dm_orig_004",
      product_id: "com.test.premium", webhook_validated: true, store: true,
      processed: true, purchase_type: "subscription"
    )
  end

  # ── Structure ──

  test "returns current and previous period structure" do
    result = DashboardMetrics.call(project_id: @pid, start_time: "2026-03-01", end_time: "2026-03-02")

    assert result.key?(:current)
    assert result.key?(:previous)

    expected_keys = %i[views link_views link_driven_installs organic_users opens installs
                       reinstalls app_opens new_users returning_users returning_rate
                       referred_users revenue units_sold cancellations first_time_purchases
                       arpu arppu]
    expected_keys.each do |key|
      assert result[:current].key?(key), "Missing key :#{key} in current"
      assert result[:previous].key?(key), "Missing key :#{key} in previous"
    end
  end

  # ── Aggregated sums from DailyProjectMetric ──

  test "sums daily project metrics for current period" do
    result = DashboardMetrics.call(project_id: @pid, start_time: "2026-03-01", end_time: "2026-03-02")
    c = result[:current]

    assert_equal 300, c[:views]            # 100 + 200
    assert_equal 30,  c[:installs]         # 10 + 20
    assert_equal 130, c[:opens]            # 50 + 80
    assert_equal 7,   c[:reinstalls]       # 2 + 5
    assert_equal 230, c[:link_views]       # 80 + 150
    assert_equal 10,  c[:referred_users]   # 3 + 7
    assert_equal 20,  c[:organic_users]    # 7 + 13
    assert_equal 3000, c[:revenue]         # 1000 + 2000
    assert_equal 13,  c[:units_sold]       # 5 + 8
    assert_equal 3,   c[:cancellations]    # 1 + 2
    assert_equal 8,   c[:first_time_purchases] # 3 + 5
    assert_equal 90,  c[:app_opens]        # 30 + 60
    assert_equal 30,  c[:new_users]        # 10 + 20
  end

  test "previous period matches current period length" do
    result = DashboardMetrics.call(project_id: @pid, start_time: "2026-03-01", end_time: "2026-03-02")
    p = result[:previous]

    # Feb 27–28 = 2 days, same as Mar 1–2
    assert_equal 110, p[:views]       # 50 + 60
    assert_equal 11,  p[:installs]    # 5 + 6
    assert_equal 55,  p[:opens]       # 25 + 30
    assert_equal 3,   p[:reinstalls]  # 1 + 2
    assert_equal 85,  p[:link_views]  # 40 + 45
    assert_equal 3,   p[:referred_users]   # 1 + 2
    assert_equal 1100, p[:revenue]    # 500 + 600
    assert_equal 5,   p[:units_sold]  # 2 + 3
    assert_equal 1,   p[:cancellations]    # 0 + 1
  end

  # ── Platform filtering ──

  test "platform filtering restricts to one platform" do
    DailyProjectMetric.create!(
      project_id: @pid, event_date: Date.new(2026, 3, 1), platform: "android",
      views: 500, installs: 50, opens: 200, reinstalls: 10, link_views: 400,
      referred_users: 20, organic_users: 30, new_users: 50, app_opens: 100,
      first_time_visitors: 40, revenue: 5000, units_sold: 20, cancellations: 5,
      first_time_purchases: 10
    )

    ios = DashboardMetrics.call(project_id: @pid, start_time: "2026-03-01", end_time: "2026-03-02", platform: "ios")
    assert_equal 300, ios[:current][:views]

    android = DashboardMetrics.call(project_id: @pid, start_time: "2026-03-01", end_time: "2026-03-02", platform: "android")
    assert_equal 500, android[:current][:views]

    all = DashboardMetrics.call(project_id: @pid, start_time: "2026-03-01", end_time: "2026-03-02")
    assert_equal 800, all[:current][:views]
  end

  # ── Derived metrics: link_driven_installs ──

  test "link_driven_installs equals installs minus organic_users" do
    result = DashboardMetrics.call(project_id: @pid, start_time: "2026-03-01", end_time: "2026-03-02")
    c = result[:current]

    # installs=30, organic_users=20 → link_driven_installs=10
    assert_equal 10, c[:link_driven_installs]
    assert_equal c[:installs] - c[:organic_users], c[:link_driven_installs]
  end

  test "link_driven_installs can be negative when organic exceeds installs" do
    # Create a metric where organic_users > installs
    DailyProjectMetric.create!(
      project_id: projects(:two).id, event_date: Date.new(2026, 3, 1), platform: "ios",
      views: 10, installs: 2, opens: 5, reinstalls: 0, link_views: 8,
      referred_users: 0, organic_users: 5, new_users: 2, app_opens: 3,
      first_time_visitors: 2, revenue: 0, units_sold: 0, cancellations: 0,
      first_time_purchases: 0
    )

    result = DashboardMetrics.call(project_id: projects(:two).id, start_time: "2026-03-01", end_time: "2026-03-01")
    # The service does installs - organic_users with no clamping
    assert_equal(-3, result[:current][:link_driven_installs])
  end

  # ── Derived metrics: returning_users and returning_rate ──

  test "returning_users is exact count of returning visitors" do
    result = DashboardMetrics.call(project_id: @pid, start_time: "2026-03-01", end_time: "2026-03-02")
    c = result[:current]

    # total_users = 2 (ios_visitor + android_visitor via VDS DISTINCT)
    # first_time_visitors = 1 (ios_visitor has no VDS before Mar 1)
    #   android_visitor has VDS on Feb 20 → NOT first-time
    # returning_users = max(2 - 1, 0) = 1
    assert_equal 1, c[:returning_users]
  end

  test "returning_rate is exact ratio of returning to total users" do
    result = DashboardMetrics.call(project_id: @pid, start_time: "2026-03-01", end_time: "2026-03-02")
    c = result[:current]

    # returning_users=1, total_users=2 → rate = 1.0/2 = 0.5
    assert_equal 0.5, c[:returning_rate]
  end

  test "returning_users and rate are zero when all visitors are first-time" do
    # Use project two which has no VDS data at all; add fresh VDS records
    pid2 = projects(:two).id
    new_visitor = Visitor.create!(project: projects(:two), device: devices(:web_device), web_visitor: true)
    VisitorDailyStatistic.create!(
      visitor: new_visitor, project_id: pid2,
      event_date: Date.new(2026, 3, 1), platform: "web", views: 1
    )
    DailyProjectMetric.create!(
      project_id: pid2, event_date: Date.new(2026, 3, 1), platform: "web",
      views: 1, installs: 0, opens: 0, reinstalls: 0, link_views: 0,
      referred_users: 0, organic_users: 0, new_users: 1, app_opens: 0,
      first_time_visitors: 1, revenue: 0, units_sold: 0, cancellations: 0,
      first_time_purchases: 0
    )

    result = DashboardMetrics.call(project_id: pid2, start_time: "2026-03-01", end_time: "2026-03-01")
    c = result[:current]

    assert_equal 0,   c[:returning_users]
    assert_equal 0.0, c[:returning_rate]
  end

  # ── Derived metrics: ARPU and ARPPU ──

  test "arpu is exact revenue divided by total unique visitors" do
    result = DashboardMetrics.call(project_id: @pid, start_time: "2026-03-01", end_time: "2026-03-02")
    c = result[:current]

    # revenue = 3000, total_users = 2 (from VDS DISTINCT visitor_id)
    # arpu = (3000.0 / 2).round(2) = 1500.0
    assert_equal 1500.0, c[:arpu]
  end

  test "arppu is exact revenue divided by unique paying users" do
    result = DashboardMetrics.call(project_id: @pid, start_time: "2026-03-01", end_time: "2026-03-02")
    c = result[:current]

    # revenue = 3000, paying_users = 2 (ios_device + android_device with BUY events)
    # arppu = (3000.0 / 2).round(2) = 1500.0
    assert_equal 1500.0, c[:arppu]
  end

  test "arpu and arppu differ when not all visitors are paying" do
    # Add a third visitor who is NOT a paying user
    third_visitor = Visitor.create!(project: @project, device: devices(:web_device), web_visitor: true)
    VisitorDailyStatistic.create!(
      visitor: third_visitor, project_id: @pid,
      event_date: Date.new(2026, 3, 1), platform: "web", views: 3
    )

    result = DashboardMetrics.call(project_id: @pid, start_time: "2026-03-01", end_time: "2026-03-02")
    c = result[:current]

    # total_users = 3, paying_users = 2, revenue = 3000
    assert_equal (3000.0 / 3).round(2), c[:arpu]   # 1000.0
    assert_equal (3000.0 / 2).round(2), c[:arppu]   # 1500.0
    assert c[:arpu] < c[:arppu], "ARPU should be less than ARPPU when non-paying users exist"
  end

  # ── Zero-data edge case ──

  test "zero data project returns zero for all numeric fields" do
    result = DashboardMetrics.call(project_id: projects(:two).id, start_time: "2026-03-01", end_time: "2026-03-02")
    c = result[:current]

    assert_equal 0,   c[:views]
    assert_equal 0,   c[:installs]
    assert_equal 0,   c[:revenue]
    assert_equal 0,   c[:returning_users]
    assert_equal 0.0, c[:arpu]
    assert_equal 0.0, c[:arppu]
    assert_equal 0.0, c[:returning_rate]
    assert_equal 0,   c[:link_driven_installs]
    assert_equal 0,   c[:referred_users]
    assert_equal 0,   c[:units_sold]
    assert_equal 0,   c[:cancellations]
    assert_equal 0,   c[:first_time_purchases]
  end

  # ── Single day period ──

  test "single day period uses previous single day" do
    result = DashboardMetrics.call(project_id: @pid, start_time: "2026-03-01", end_time: "2026-03-01")

    assert_equal 100, result[:current][:views]
    # Previous = Feb 28 (1 day before)
    assert_equal 60, result[:previous][:views]
  end

  # ── Platform-filtered ARPU/ARPPU ──

  test "platform-filtered arpu uses only platform-specific visitors" do
    # With platform: "ios":
    #   unique_visitors_for_range filters VDS by platform="ios" → only @visitor_a (1 visitor)
    #   revenue from DPM with platform="ios" = 1000 + 2000 = 3000
    #   arpu = 3000.0 / 1 = 3000.0
    result = DashboardMetrics.call(project_id: @pid, start_time: "2026-03-01", end_time: "2026-03-02", platform: "ios")
    c = result[:current]

    assert_equal 3000.0, c[:arpu]
  end

  test "platform-filtered arppu uses only platform-specific paying users" do
    # With platform: "ios":
    #   unique_paying_users_for_range joins devices and filters devices.platform="ios"
    #   → only @ios_device (1 paying user)
    #   revenue from DPM with platform="ios" = 3000
    #   arppu = 3000.0 / 1 = 3000.0
    result = DashboardMetrics.call(project_id: @pid, start_time: "2026-03-01", end_time: "2026-03-02", platform: "ios")
    c = result[:current]

    assert_equal 3000.0, c[:arppu]
  end

  test "platform-filtered arpu differs from unfiltered arpu" do
    # Unfiltered: total_users = 2 (ios_visitor + android_visitor), revenue = 3000
    #   arpu = 3000.0 / 2 = 1500.0
    # ios-filtered: total_users = 1 (ios_visitor only), revenue = 3000
    #   arpu = 3000.0 / 1 = 3000.0
    all_result = DashboardMetrics.call(project_id: @pid, start_time: "2026-03-01", end_time: "2026-03-02")
    ios_result = DashboardMetrics.call(project_id: @pid, start_time: "2026-03-01", end_time: "2026-03-02", platform: "ios")

    assert_equal 1500.0, all_result[:current][:arpu]
    assert_equal 3000.0, ios_result[:current][:arpu]
    assert ios_result[:current][:arpu] > all_result[:current][:arpu],
      "iOS-filtered ARPU should be higher since fewer visitors share the same revenue"
  end

  # ── Platform-filtered returning users ──

  test "platform-filtered returning users excludes other platform visitors" do
    # Without platform filter:
    #   total_users = 2, first_time = 1 (ios_visitor), returning = 1 (android_visitor)
    # With platform: "ios":
    #   unique_visitors_for_range(platform="ios") → 1 (only @visitor_a with ios VDS)
    #   unique_first_time_visitors_for_range(platform="ios") uses "AND c.platform = ?"
    #     → @visitor_a has ios VDS on Mar 1-2 with no prior VDS → first_time = 1
    #   returning = max(1 - 1, 0) = 0
    unfiltered = DashboardMetrics.call(project_id: @pid, start_time: "2026-03-01", end_time: "2026-03-02")
    ios_filtered = DashboardMetrics.call(project_id: @pid, start_time: "2026-03-01", end_time: "2026-03-02", platform: "ios")

    assert_equal 1, unfiltered[:current][:returning_users]
    assert_equal 0, ios_filtered[:current][:returning_users]
  end

  test "platform-filtered returning users counts returning visitors on that platform" do
    # With platform: "android":
    #   unique_visitors_for_range(platform="android") → 1 (@visitor_b has android VDS on Mar 1)
    #   unique_first_time_visitors_for_range(platform="android") uses "AND c.platform = ?"
    #     → @visitor_b has android VDS on Mar 1, but also has android VDS on Feb 20 (before range)
    #     → NOT first-time → first_time = 0
    #   returning = max(1 - 0, 0) = 1
    android_result = DashboardMetrics.call(project_id: @pid, start_time: "2026-03-01", end_time: "2026-03-02", platform: "android")

    assert_equal 1, android_result[:current][:returning_users]
    assert_equal 1.0, android_result[:current][:returning_rate]
  end
end
