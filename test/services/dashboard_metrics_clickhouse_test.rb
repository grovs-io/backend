# frozen_string_literal: true

require "test_helper"

class DashboardMetricsClickhouseTest < ActiveSupport::TestCase
  include ClickhouseTestHelper

  fixtures :projects, :instances, :devices, :visitors, :domains, :links, :redirect_configs

  setup do
    skip_unless_clickhouse!
    @ch_auto_rebuild_breakdowns = true
    @project = projects(:one)
    @pid = @project.id

    VisitorDailyStatistic.where(project_id: @pid).delete_all
    PurchaseEvent.where(project_id: @pid).delete_all

    @original_read = Rails.application.config.clickhouse_read_enabled
    @original_rollups = Rails.application.config.clickhouse_analytics_rollups_read_enabled
    Rails.application.config.clickhouse_read_enabled = true
    Rails.application.config.clickhouse_analytics_rollups_read_enabled = true
  end

  teardown do
    Rails.application.config.clickhouse_read_enabled = @original_read
    Rails.application.config.clickhouse_analytics_rollups_read_enabled = @original_rollups
  end

  # ---------------------------------------------------------------------------
  # 3c — installs folding at the dashboard seam
  # ---------------------------------------------------------------------------

  test "dashboard installs fold reinstalls, matching PG daily_project_metrics semantics" do
    # CH rollup: 3 pure installs + 2 reinstalls. PG DPM says 999 to prove the source.
    insert_project_rollup([
      project_row("2026-03-01", installs: 3),
      project_row("2026-03-02", reinstalls: 2)
    ])
    create_dpm(Date.new(2026, 3, 1), installs: 999, reinstalls: 999)

    current = call_dashboard(Date.new(2026, 3, 1), Date.new(2026, 3, 2))

    assert_equal 5, current[:installs]
    assert_equal 2, current[:reinstalls]
  end

  test "link_driven_installs stays consistent with folded installs" do
    insert_project_rollup([project_row("2026-04-01", installs: 1, reinstalls: 1)])
    # PG organic_users = 2 (folded legacy formula); pure CH installs (1) would go negative
    create_dpm(Date.new(2026, 4, 1), installs: 2, reinstalls: 1, organic_users: 2)

    current = call_dashboard(Date.new(2026, 4, 1), Date.new(2026, 4, 1))

    assert_equal 2, current[:installs]
    assert_operator current[:link_driven_installs], :>=, 0
  end

  test "flag off serves folded installs from PG untouched" do
    Rails.application.config.clickhouse_analytics_rollups_read_enabled = false
    create_dpm(Date.new(2026, 3, 10), installs: 12, reinstalls: 3)

    current = call_dashboard(Date.new(2026, 3, 10), Date.new(2026, 3, 10))

    assert_equal 12, current[:installs]
    assert_equal 3, current[:reinstalls]
  end

  # ---------------------------------------------------------------------------
  # 3a — unique visitors from CH
  # ---------------------------------------------------------------------------

  test "unique visitors without platform filter come from the billing rollup" do
    # Prior-month events push first-seen outside the range → first_time_visitors 0,
    # so returning_users equals the range's unique count. CH: 2 visitors; PG VDS: 1.
    insert_events([
      event(visitor_id: 11, device_id: 1, event_type: "view", date: "2026-04-20"),
      event(visitor_id: 12, device_id: 2, event_type: "view", date: "2026-04-20"),
      event(visitor_id: 11, device_id: 1, event_type: "view", date: "2026-05-01"),
      event(visitor_id: 12, device_id: 2, event_type: "view", date: "2026-05-01")
    ])
    VisitorDailyStatistic.create!(
      visitor: visitors(:ios_visitor), project_id: @pid,
      event_date: Date.new(2026, 5, 1), platform: "ios", views: 1
    )

    current = call_dashboard(Date.new(2026, 5, 1), Date.new(2026, 5, 1))

    assert_equal 2, current[:returning_users]
  end

  test "platform-filtered unique visitors normalize raw platforms into web" do
    # Two visitors on raw 'mac' + one on 'ios'; requesting web must count the mac pair
    insert_events([
      event(visitor_id: 21, device_id: 21, event_type: "view", date: "2026-06-01", platform: "mac"),
      event(visitor_id: 22, device_id: 22, event_type: "view", date: "2026-06-01", platform: "mac"),
      event(visitor_id: 23, device_id: 23, event_type: "view", date: "2026-06-01", platform: "ios")
    ])

    count = ClickhouseReadService.unique_visitors_by_platform(
      @pid, start_date: Date.new(2026, 6, 1), end_date: Date.new(2026, 6, 1), platforms: ["web"]
    )

    assert_equal 2, count
  end

  test "a custom-event-only visitor is not a user on the platform-filtered path either" do
    insert_events([
      event(visitor_id: 41, device_id: 41, event_type: "view", date: "2026-06-07", platform: "ios"),
      event(visitor_id: 42, device_id: 42, event_type: "custom", date: "2026-06-07", platform: "ios")
    ])

    count = ClickhouseReadService.unique_visitors_by_platform(
      @pid, start_date: Date.new(2026, 6, 7), end_date: Date.new(2026, 6, 7), platforms: ["ios"]
    )

    assert_equal 1, count, "the denominator must be the billable population on every surface"
  end

  test "multi-platform unique visitors count a visitor once across the selected set" do
    insert_events([
      event(visitor_id: 31, device_id: 31, event_type: "view", date: "2026-06-05", platform: "ios"),
      event(visitor_id: 31, device_id: 31, event_type: "open", date: "2026-06-05", platform: "mac")
    ])

    count = ClickhouseReadService.unique_visitors_by_platform(
      @pid, start_date: Date.new(2026, 6, 5), end_date: Date.new(2026, 6, 5), platforms: %w[ios web]
    )

    assert_equal 1, count
  end

  test "nil unique-visitor reads fall back to PG" do
    # No CH events → first_seen totals are 0, so returning_users = PG unique count
    VisitorDailyStatistic.create!(
      visitor: visitors(:ios_visitor), project_id: @pid,
      event_date: Date.new(2026, 7, 1), platform: "ios", views: 1
    )

    ClickhouseReadService.stub(:billing_active_visitors, nil) do
      current = call_dashboard(Date.new(2026, 7, 1), Date.new(2026, 7, 1))

      assert_equal 1, current[:returning_users]
    end
  end

  # ---------------------------------------------------------------------------
  # 3b — new users + first-time visitors from visitor_first_seen_daily
  # ---------------------------------------------------------------------------

  test "new and first-time users come from CH first-seen; purchase columns stay PG" do
    # 41 first seen via view (first-time, not new); 42 installs on day one (first-time AND new).
    insert_events([
      event(visitor_id: 41, device_id: 1, event_type: "view", date: "2026-08-01"),
      event(visitor_id: 42, device_id: 2, event_type: "install", date: "2026-08-01")
    ])
    create_dpm(Date.new(2026, 8, 1), new_users: 9, first_time_visitors: 9, revenue: 1234)

    current = call_dashboard(Date.new(2026, 8, 1), Date.new(2026, 8, 1))

    assert_equal 1, current[:new_users]
    assert_equal 1234, current[:revenue]
  end

  test "link_views sums the link rollup, not daily_project_metrics" do
    link_id = links(:basic_link).id
    insert_link_rollup([
      link_row(link_id, "2026-08-05", views: 4),
      link_row(link_id, "2026-08-06", views: 6)
    ])
    create_dpm(Date.new(2026, 8, 5), link_views: 77)

    current = call_dashboard(Date.new(2026, 8, 5), Date.new(2026, 8, 6))

    assert_equal 10, current[:link_views]
  end

  test "link_views platform filter normalizes raw platforms into web" do
    link_id = links(:basic_link).id
    insert_link_rollup([
      link_row(link_id, "2026-08-07", views: 3, platform: "mac"),
      link_row(link_id, "2026-08-07", views: 5, platform: "ios")
    ])

    current = call_dashboard(Date.new(2026, 8, 7), Date.new(2026, 8, 7), platform: "web")

    assert_equal 3, current[:link_views]
  end

  test "referred_users counts DISTINCT referred people, not visitor-days" do
    insert_visitor_rollup([
      visitor_row(81, "2026-08-10", inviter_id: 5),
      visitor_row(82, "2026-08-10", inviter_id: 5),
      visitor_row(83, "2026-08-10"),                  # no inviter
      visitor_row(81, "2026-08-11", inviter_id: 5)    # 81 again the next day
    ])
    create_dpm(Date.new(2026, 8, 10), referred_users: 99)

    current = call_dashboard(Date.new(2026, 8, 10), Date.new(2026, 8, 11))

    assert_equal 2, current[:referred_users],
                 "81 and 82 — 81's second active day must not count twice (PG says 3 rows)"
  end

  test "referred_users drops a merge-created self-referral but keeps a plain self-invite" do
    insert_visitor_rollup([
      visitor_row(91, "2026-08-12", inviter_id: 92),
      visitor_row(93, "2026-08-12", inviter_id: 93)
    ])
    alias_visitor(92, 91)
    create_dpm(Date.new(2026, 8, 12), referred_users: 99)

    current = call_dashboard(Date.new(2026, 8, 12), Date.new(2026, 8, 12))

    assert_equal 1, current[:referred_users], "92 folds onto 91, self-crediting; 93 is real data"
  end

  test "referred_users counts one person across a merge's two identities" do
    insert_visitor_rollup([
      visitor_row(94, "2026-08-13", inviter_id: 5),
      visitor_row(95, "2026-08-13", inviter_id: 5)
    ])
    alias_visitor(95, 94)
    create_dpm(Date.new(2026, 8, 13), referred_users: 99)

    current = call_dashboard(Date.new(2026, 8, 13), Date.new(2026, 8, 13))

    assert_equal 1, current[:referred_users], "95 folds onto 94; PG counts one visitor post-merge"
  end

  test "referred_users drops a self-invite once a merge sweeps it up" do
    insert_visitor_rollup([visitor_row(96, "2026-08-14", inviter_id: 96)])
    alias_visitor(96, 97)
    create_dpm(Date.new(2026, 8, 14), referred_users: 99)

    current = call_dashboard(Date.new(2026, 8, 14), Date.new(2026, 8, 14))

    assert_equal 0, current[:referred_users], "PG's repoint_referrals NULLs this row"
  end

  test "nil link_views and referred_users reads fall back to PG" do
    create_dpm(Date.new(2026, 8, 20), link_views: 55, referred_users: 7)

    ClickhouseReadService.stub(:link_views_total, nil) do
      ClickhouseReadService.stub(:referred_users_total, nil) do
        current = call_dashboard(Date.new(2026, 8, 20), Date.new(2026, 8, 20))

        assert_equal 55, current[:link_views]
        assert_equal 7, current[:referred_users]
      end
    end
  end

  test "a CH read that fell back to PG caches only briefly" do
    create_dpm(Date.new(2026, 9, 15), link_views: 55)

    ClickhouseReadService.stub(:link_views_total, nil) do
      DashboardMetrics.call(project_id: @pid, start_time: Date.new(2026, 9, 15),
                            end_time: Date.new(2026, 9, 15))
    end

    # CH recovers; the degraded payload must have expired rather than pinning PG's 55.
    insert_link_rollup([link_row(links(:basic_link).id, "2026-09-15", views: 9)])
    travel RevenueLedger::DEGRADED_CACHE_TTL + 1.second do
      current = call_dashboard(Date.new(2026, 9, 15), Date.new(2026, 9, 15))

      assert_equal 9, current[:link_views]
    end
  end

  test "degraded markers never leak into the response" do
    create_dpm(Date.new(2026, 9, 16), link_views: 5)

    current = call_dashboard(Date.new(2026, 9, 16), Date.new(2026, 9, 16))

    assert_not current.key?(:ch_degraded)
    assert_not current.key?(:ledger_degraded)
  end

  test "flag off keeps link_views and referred_users on PG" do
    Rails.application.config.clickhouse_analytics_rollups_read_enabled = false
    create_dpm(Date.new(2026, 8, 25), link_views: 42, referred_users: 3)

    current = call_dashboard(Date.new(2026, 8, 25), Date.new(2026, 8, 25))

    assert_equal 42, current[:link_views]
    assert_equal 3, current[:referred_users]
  end

  test "CH first_time_visitors drive returning_users and returning_rate" do
    # 4 unique in range; 3 seen in a prior month, 1 first-time → returning 3, rate 0.75
    insert_events([
      event(visitor_id: 61, device_id: 1, event_type: "view", date: "2026-11-20"),
      event(visitor_id: 62, device_id: 2, event_type: "view", date: "2026-11-20"),
      event(visitor_id: 63, device_id: 3, event_type: "view", date: "2026-11-20"),
      event(visitor_id: 61, device_id: 1, event_type: "view", date: "2026-12-01"),
      event(visitor_id: 62, device_id: 2, event_type: "view", date: "2026-12-01"),
      event(visitor_id: 63, device_id: 3, event_type: "view", date: "2026-12-01"),
      event(visitor_id: 64, device_id: 4, event_type: "view", date: "2026-12-01")
    ])

    current = call_dashboard(Date.new(2026, 12, 1), Date.new(2026, 12, 1))

    assert_equal 3, current[:returning_users]
    assert_in_delta 0.75, current[:returning_rate], 0.001
  end

  test "nil first-seen read uses PG first_time_visitors for returning math" do
    insert_events([
      event(visitor_id: 71, device_id: 1, event_type: "view", date: "2027-02-01"),
      event(visitor_id: 72, device_id: 2, event_type: "view", date: "2027-02-01")
    ])
    create_dpm(Date.new(2027, 2, 1), first_time_visitors: 1)

    ClickhouseReadService.stub(:first_seen_daily, nil) do
      current = call_dashboard(Date.new(2027, 2, 1), Date.new(2027, 2, 1))

      # CH unique 2 − PG ftv 1
      assert_equal 1, current[:returning_users]
      assert_in_delta 0.5, current[:returning_rate], 0.001
    end
  end

  test "nil first-seen read falls back to PG derived columns" do
    create_dpm(Date.new(2026, 9, 1), new_users: 6, first_time_visitors: 4)

    ClickhouseReadService.stub(:first_seen_daily, nil) do
      current = call_dashboard(Date.new(2026, 9, 1), Date.new(2026, 9, 1))

      assert_equal 6, current[:new_users]
    end
  end

  # ---------------------------------------------------------------------------
  # Normalization regression on shipped readers
  # ---------------------------------------------------------------------------

  test "project_metrics_daily_totals with web filter includes raw mac rows" do
    insert_project_rollup([project_row("2026-10-01", views: 1, platform: "mac")])

    totals = ClickhouseReadService.project_metrics_daily_totals(
      @pid, start_date: Date.new(2026, 10, 1), end_date: Date.new(2026, 10, 1), platform: "web"
    )

    assert_equal 1, totals[:views]
  end

  test "link_metrics_by_id with web filter includes raw mac rows" do
    link_id = links(:basic_link).id
    insert_link_rollup([link_row(link_id, "2026-10-02", views: 1, platform: "mac")])

    rows = ClickhouseReadService.link_metrics_by_id(
      @pid, link_ids: [link_id], start_date: Date.new(2026, 10, 2), end_date: Date.new(2026, 10, 2), platform: "web"
    )

    assert_equal 1, rows.first["views"].to_i
  end

  test "top_link_metrics with web filter includes raw mac rows" do
    link_id = links(:basic_link).id
    insert_link_rollup([link_row(link_id, "2026-10-03", installs: 1, platform: "mac")])

    rows = ClickhouseReadService.top_link_metrics(
      @pid, link_ids: [link_id], start_date: Date.new(2026, 10, 3), end_date: Date.new(2026, 10, 3), platform: "web"
    )

    assert_equal 1, rows.first["installs"].to_i
  end

  private

  def call_dashboard(start_date, end_date, platform: nil)
    DashboardMetrics.call(
      project_id: @pid, start_time: start_date, end_time: end_date, platform: platform
    )[:current]
  end

  def create_dpm(date, attrs = {})
    DailyProjectMetric.create!(
      { project_id: @pid, event_date: date, platform: "ios",
        views: 0, installs: 0, opens: 0, reinstalls: 0, link_views: 0,
        referred_users: 0, organic_users: 0, new_users: 0, app_opens: 0,
        first_time_visitors: 0, revenue: 0, units_sold: 0, cancellations: 0,
        first_time_purchases: 0 }.merge(attrs)
    )
  end

  def project_row(date, platform: "ios", views: 0, opens: 0, installs: 0, reinstalls: 0, app_opens: 0)
    { project_id: @pid, event_date: date, platform: platform, views: views, opens: opens,
      installs: installs, reinstalls: reinstalls, app_opens: app_opens,
      unique_visitors: 0, unique_devices: 0 }
  end

  def visitor_row(visitor_id, date, platform: "ios", views: 1, inviter_id: 0)
    { project_id: @pid, visitor_id: visitor_id, event_date: date, platform: platform,
      views: views, opens: 0, installs: 0, reinstalls: 0, time_spent: 0,
      reactivations: 0, app_opens: 0, user_referred: 0, inviter_id: inviter_id }
  end

  def link_row(link_id, date, platform: "ios", views: 0, installs: 0)
    { project_id: @pid, link_id: link_id, event_date: date, platform: platform,
      views: views, opens: 0, installs: installs, reinstalls: 0, time_spent: 0,
      reactivations: 0, app_opens: 0, user_referred: 0 }
  end

  def insert_project_rollup(rows)
    Clickhouse.with { |conn| conn.insert("project_metrics_daily", rows) }
  end

  def alias_visitor(from_id, to_id)
    Clickhouse.with do |conn|
      conn.insert("visitor_identity_map",
                  [{ project_id: @pid, from_visitor_id: from_id, to_visitor_id: to_id,
                     updated_at: Time.current.utc.strftime("%Y-%m-%d %H:%M:%S.%3N") }])
    end
  end

  def insert_visitor_rollup(rows)
    Clickhouse.with { |conn| conn.insert("visitor_metrics_daily", rows) }
  end

  def insert_link_rollup(rows)
    Clickhouse.with { |conn| conn.insert("link_metrics_daily", rows) }
  end

  def event(visitor_id:, device_id:, event_type:, date:, platform: "ios", link_id: 0)
    {
      project_id: @pid, event_type: event_type, device_id: device_id,
      visitor_id: visitor_id, link_id: link_id, inviter_id: 0, campaign_id: 0,
      platform: platform, engagement_time: 0, country: "",
      created_at: Time.utc(*date.split("-").map(&:to_i), 12, 0, 0).strftime("%Y-%m-%d %H:%M:%S.000")
    }
  end

  def insert_events(rows)
    insert_ch_events(rows)
  end
end
