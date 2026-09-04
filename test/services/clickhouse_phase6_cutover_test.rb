# frozen_string_literal: true

require "test_helper"

# Phase 6 (non-destructive) cutover safety. Proves:
#   * flag OFF (default) → routed dashboard readers return the SAME PG result and
#     NEVER query ClickHouse,
#   * flag ON → the same readers return the CH-backed result for an equivalent dataset,
#   * the flag flip is reversible (ON then OFF → PG again),
#   * billing/MAU and quota readers IGNORE the dashboard flags (stay on Postgres).
class ClickhousePhase6CutoverTest < ActiveSupport::TestCase
  include ClickhouseTestHelper
  include ChQueryCounter

  fixtures :instances, :projects, :devices, :visitors

  PLATFORM = "ios"

  FLAG_ACCESSORS = %i[
    clickhouse_read_enabled
    clickhouse_analytics_rollups_read_enabled
    clickhouse_attribution_read_enabled
  ].freeze

  setup do
    @project = projects(:one)
    @pid = @project.id
    @date = Date.new(2026, 6, 10)
    Rails.cache.clear
    DailyProjectMetric.where(project_id: @pid).delete_all
    VisitorDailyStatistic.where(project_id: @pid).delete_all
    PurchaseEvent.where(project_id: @pid).delete_all
    # Capture the run's flag values so teardown restores them. Forcing the flags
    # OFF is the per-test baseline, but they MUST be restored afterwards —
    # Rails.application.config is process-global per worker, so leaving them off
    # would disable CH reads for every later test on this worker (e.g. attribution
    # reads silently returning []).
    @original_flags = FLAG_ACCESSORS.index_with { |f| Rails.application.config.public_send(f) }
    flags_off
  end

  teardown do
    @original_flags&.each { |f, v| Rails.application.config.public_send("#{f}=", v) }
  end

  def flags_off
    FLAG_ACCESSORS.each { |f| Rails.application.config.public_send("#{f}=", false) }
  end

  # ── DashboardMetrics: flag OFF must not touch CH ──────────────────────────

  test "dashboard countable metrics: flag OFF returns PG sums and queries NO ClickHouse" do
    seed_pg_project(views: 100, opens: 50, installs: 10, reinstalls: 2, app_opens: 30)

    n = count_ch_queries do
      result = DashboardMetrics.call(project_id: @pid, start_time: @date, end_time: @date)
      c = result[:current]
      assert_equal 100, c[:views]
      assert_equal 50,  c[:opens]
      assert_equal 10,  c[:installs]
      assert_equal 2,   c[:reinstalls]
      assert_equal 30,  c[:app_opens]
    end
    assert_equal 0, n, "flag OFF must not execute any ClickHouse query"
  end

  test "dashboard countable metrics: flag ON reads the CH rollup, OFF reverts to PG" do
    skip_unless_clickhouse!
    # PG and CH disagree on purpose so we can PROVE which store served the read.
    seed_pg_project(views: 100, opens: 50, installs: 10, reinstalls: 2, app_opens: 30)
    seed_ch_project_rollup(views: 777, opens: 50, installs: 10, reinstalls: 2, app_opens: 30)

    # OFF → PG value.
    Rails.cache.clear
    assert_equal 100, DashboardMetrics.call(project_id: @pid, start_time: @date, end_time: @date)[:current][:views]

    # ON → CH value.
    Rails.application.config.clickhouse_read_enabled = true
    Rails.application.config.clickhouse_analytics_rollups_read_enabled = true
    Rails.cache.clear
    assert_equal 777, DashboardMetrics.call(project_id: @pid, start_time: @date, end_time: @date)[:current][:views]

    # Reversible: OFF again → PG value.
    flags_off
    Rails.cache.clear
    assert_equal 100, DashboardMetrics.call(project_id: @pid, start_time: @date, end_time: @date)[:current][:views]
  end

  test "dashboard purchase columns stay on PG; organic and link_views move to CH when the flag is ON" do
    skip_unless_clickhouse!
    seed_pg_project(views: 1, opens: 1, installs: 1, reinstalls: 1, app_opens: 1,
                    revenue: 4242, organic_users: 9, link_views: 11)
    seed_ch_project_rollup(views: 1, opens: 1, installs: 1, reinstalls: 1, app_opens: 1)
    # CH organic inputs: visitor installs 3, link installs 1 → organic 2 (≠ PG's 9)
    Clickhouse.with do |conn|
      conn.insert("visitor_metrics_daily", [{
        project_id: @pid, visitor_id: 90_101, event_date: @date, platform: PLATFORM,
        views: 0, opens: 0, installs: 3, reinstalls: 0, time_spent: 0,
        reactivations: 0, app_opens: 0, user_referred: 0, inviter_id: 0
      }])
      conn.insert("link_metrics_daily", [{
        project_id: @pid, link_id: 90_102, event_date: @date, platform: PLATFORM,
        views: 5, opens: 0, installs: 1, reinstalls: 0, time_spent: 0,
        reactivations: 0, app_opens: 0, user_referred: 0
      }])
    end

    Rails.application.config.clickhouse_read_enabled = true
    Rails.application.config.clickhouse_analytics_rollups_read_enabled = true
    Rails.cache.clear

    c = DashboardMetrics.call(project_id: @pid, start_time: @date, end_time: @date)[:current]
    assert_equal 4242, c[:revenue], "revenue is uncovered by the rollup — must come from PG"
    assert_equal 5, c[:link_views], "link_views is served from the link rollup (PG says 11)"
    assert_equal 2, c[:organic_users], "organic_users is served from CH when the flag is ON"

    ClickhouseReadService.stub :organic_users_total, nil do
      ClickhouseReadService.stub :link_views_total, nil do
        Rails.cache.clear
        fallback = DashboardMetrics.call(project_id: @pid, start_time: @date, end_time: @date)[:current]
        assert_equal 9, fallback[:organic_users], "nil CH organic read must fall back to PG"
        assert_equal 11, fallback[:link_views], "nil CH link_views read must fall back to PG"
      end
    end
  end

  test "dashboard countable metrics: flag ON but CH read FAILS (nil) falls back to PG, not zeros" do
    seed_pg_project(views: 100, opens: 50, installs: 10, reinstalls: 2, app_opens: 30)

    Rails.application.config.clickhouse_read_enabled = true
    Rails.application.config.clickhouse_analytics_rollups_read_enabled = true
    Rails.cache.clear

    # A failed/unavailable CH read returns nil — DashboardMetrics must serve PG, not zeros.
    ClickhouseReadService.stub :project_metrics_daily_totals, nil do
      c = DashboardMetrics.call(project_id: @pid, start_time: @date, end_time: @date)[:current]
      assert_equal 100, c[:views], "nil CH read must fall back to the PG value"
      assert_equal 50, c[:opens]
      assert_equal 10, c[:installs]
    end
  end

  # ── OverviewStatsService.versions / version_distribution flag routing ─────

  test "versions: flag OFF uses raw events path and does NOT call the rollup reader" do
    called = false
    ClickhouseReadService.stub :project_version_daily_stats, lambda { |*, **|
      called = true
      []
    } do
      result = Analytics::OverviewStatsService.versions(@pid, start_date: @date, end_date: @date)
      assert result.key?(:platforms)
    end
    assert_not called, "flag OFF must not consult the CH version rollup reader"
  end

  test "versions: flag ON routes to the CH version rollup reader" do
    Rails.application.config.clickhouse_read_enabled = true
    Rails.application.config.clickhouse_analytics_rollups_read_enabled = true

    sentinel = [{ "platform" => "ios", "version" => "9.9.9", "users" => 42 }]
    ClickhouseReadService.stub :project_version_daily_stats, ->(*, **) { sentinel } do
      result = Analytics::OverviewStatsService.versions(@pid, start_date: @date, end_date: @date)
      ios = result[:platforms]["ios"]
      assert_equal 1, ios.size, "flag ON must serve the CH rollup rows"
      assert_equal "9.9.9", ios.first[:version]
      assert_equal 42, ios.first[:users]
    end
  end

  test "versions: flag ON but CH reader RAISES returns empty (graceful), not a crash" do
    Rails.application.config.clickhouse_read_enabled = true
    Rails.application.config.clickhouse_analytics_rollups_read_enabled = true

    ClickhouseReadService.stub :project_version_daily_stats, ->(*, **) { raise "ch down" } do
      result = Analytics::OverviewStatsService.versions(@pid, start_date: @date, end_date: @date)
      assert_equal({ platforms: {} }, result)
    end
  end

  test "version_distribution: flag OFF uses raw events path and does NOT call the rollup reader" do
    called = false
    ClickhouseReadService.stub :project_version_distribution_stats, lambda { |*, **|
      called = true
      []
    } do
      result = Analytics::OverviewStatsService.version_distribution(@pid, start_date: @date, end_date: @date)
      assert result.key?(:entries)
    end
    assert_not called, "flag OFF must not consult the CH version-distribution rollup reader"
  end

  test "version_distribution: flag ON routes to the CH rollup reader" do
    Rails.application.config.clickhouse_read_enabled = true
    Rails.application.config.clickhouse_analytics_rollups_read_enabled = true

    sentinel = [{ "version" => "7.7.7", "platform" => "ios", "users" => 13 }]
    ClickhouseReadService.stub :project_version_distribution_stats, ->(*, **) { sentinel } do
      ClickhouseReadService.stub :project_version_release_dates, ->(*, **) { [] } do
        result = Analytics::OverviewStatsService.version_distribution(@pid, start_date: @date, end_date: @date)
        assert_equal 1, result[:entries].size
        assert_equal "7.7.7", result[:entries].first[:version]
        assert_equal 13, result[:entries].first[:total]
      end
    end
  end

  # ── OverviewStatsService.sources_breakdown attribution seam ───────────────

  test "sources_breakdown: attribution flag OFF does not use the attribution reader" do
    # With both dashboard flags off the legacy raw-events path runs; the per-visitor
    # attribution reader must NOT be consulted (the stub flunks if it is).
    called = false
    ClickhouseAttributionReadService.stub :source_breakdown, lambda { |*, **|
      called = true
      []
    } do
      result = Analytics::OverviewStatsService.sources_breakdown(@pid, start_date: @date, end_date: @date)
      assert_kind_of Hash, result
      assert result.key?(:sources)
    end
    assert_not called, "attribution reader must not be called when the attribution flag is OFF"
  end

  test "sources_breakdown: attribution flag ON routes to the per-visitor attribution reader" do
    skip_unless_clickhouse!
    Rails.application.config.clickhouse_read_enabled = true
    Rails.application.config.clickhouse_attribution_read_enabled = true

    called = false
    fake = [{ "source" => "campaigns", "visitors" => 5 }]
    ClickhouseAttributionReadService.stub :source_breakdown, lambda { |*, **|
      called = true
      fake
    } do
      result = Analytics::OverviewStatsService.sources_breakdown(
        @pid, start_date: @date, end_date: @date
      )
      assert called, "attribution reader must be used when the attribution flag is ON"
      assert_equal 5, result[:total]
    end
  end

  test "sources_breakdown: rollup flag ON but CH reader RAISES returns empty (graceful)" do
    Rails.application.config.clickhouse_read_enabled = true
    Rails.application.config.clickhouse_analytics_rollups_read_enabled = true

    # The rollup path has no PG fallback; a CH failure must degrade to an empty result,
    # never raise into the controller.
    ClickhouseReadService.stub :project_source_daily_stats, ->(*, **) { raise "ch down" } do
      result = Analytics::OverviewStatsService.sources_breakdown(@pid, start_date: @date, end_date: @date)
      assert_equal({ sources: [], total: 0 }, result)
    end
  end

  test "sources_breakdown: attribution flag ON but CH reader RAISES returns empty (graceful)" do
    Rails.application.config.clickhouse_read_enabled = true
    Rails.application.config.clickhouse_attribution_read_enabled = true

    ClickhouseAttributionReadService.stub :source_breakdown, ->(*, **) { raise "ch down" } do
      result = Analytics::OverviewStatsService.sources_breakdown(@pid, start_date: @date, end_date: @date)
      assert_equal({ sources: [], total: 0 }, result)
    end
  end

  # ── Billing / MAU / quota are UNTOUCHED by the dashboard flags ────────────

  test "billing MAU reader (ProjectService) does NOT consult the dashboard cutover flags" do
    # Turn the dashboard flags ON; billing must still read Postgres VisitorDailyStatistic.
    Rails.application.config.clickhouse_analytics_rollups_read_enabled = true
    Rails.application.config.clickhouse_attribution_read_enabled = true

    src = File.read(Rails.root.join("app/services/project_service.rb"))
    assert_not_includes src, "analytics_rollups_read_enabled",
      "billing/MAU must not gate on the dashboard rollup flag"
    assert_not_includes src, "attribution_read_enabled",
      "billing/MAU must not gate on the attribution flag"
  end

  test "quota disable job does NOT consult the dashboard cutover flags" do
    src = File.read(Rails.root.join("app/jobs/disable_quotas_job.rb"))
    assert_not_includes src, "analytics_rollups_read_enabled"
    assert_not_includes src, "attribution_read_enabled"
  end

  private

  def seed_pg_project(metrics)
    DailyProjectMetric.create!(
      { project_id: @pid, event_date: @date, platform: PLATFORM }.merge(metrics)
    )
  end

  def seed_ch_project_rollup(metrics)
    row = { project_id: @pid, event_date: @date.to_s, platform: PLATFORM,
            views: 0, opens: 0, installs: 0, reinstalls: 0, app_opens: 0,
            unique_visitors: 0, unique_devices: 0 }.merge(metrics)
    Clickhouse.with { |conn| conn.insert("project_metrics_daily", [row]) }
  end
end
