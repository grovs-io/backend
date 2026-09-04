# frozen_string_literal: true

require "test_helper"

# CH path for campaigns/search_v2: metrics from link_daily, revenue from PG.
# CH values deliberately differ from PG rows so each number's source is provable.
class CampaignStatisticsQueryClickhouseTest < ActiveSupport::TestCase
  include ClickhouseTestHelper

  fixtures :projects, :instances, :domains, :links, :campaigns, :redirect_configs

  setup do
    skip_unless_clickhouse!
    truncate_clickhouse_tables
    @project = projects(:one)

    @busy = Campaign.create!(name: "CH Busy Campaign", project: @project)
    @other = Campaign.create!(name: "CH Other Campaign", project: @project)
    @quiet = Campaign.create!(name: "Quiet Campaign", project: @project)
    @link = Link.create!(
      domain: domains(:one), redirect_config: redirect_configs(:one),
      path: "ch-campaign-#{SecureRandom.hex(4)}", campaign: @busy,
      active: true, sdk_generated: false, data: "[]", generated_from_platform: "ios"
    )

    # PG stats: counts differ from CH (prove the metrics source); revenue is PG-only.
    LinkDailyStatistic.insert_all([
      { link_id: @link.id, project_id: @project.id, event_date: Date.new(2026, 3, 1), platform: "ios",
        views: 1, opens: 1, installs: 1, reinstalls: 1, time_spent: 1, reactivations: 1,
        app_opens: 1, user_referred: 1, revenue: 999, created_at: Time.current, updated_at: Time.current },
      { link_id: @link.id, project_id: @project.id, event_date: Date.new(2026, 3, 2), platform: "ios",
        views: 1, opens: 1, installs: 1, reinstalls: 1, time_spent: 1, reactivations: 1,
        app_opens: 1, user_referred: 1, revenue: 1999, created_at: Time.current, updated_at: Time.current }
    ])

    @original_read = Rails.application.config.clickhouse_read_enabled
    @original_rollups = Rails.application.config.clickhouse_analytics_rollups_read_enabled
    Rails.application.config.clickhouse_read_enabled = true
    Rails.application.config.clickhouse_analytics_rollups_read_enabled = true
    # Pin the ledger flag so a CI env with REVENUE_READS_FROM_LEDGER=true can't flip legacy assertions.
    @original_ledger = Rails.application.config.revenue_reads_from_ledger
    Rails.application.config.revenue_reads_from_ledger = false

    insert_link_daily([
      ld_row(@busy.id, "view", "ios", 100),
      ld_row(@busy.id, "open", "ios", 50),
      ld_row(@busy.id, "install", "ios", 10),
      ld_row(@busy.id, "reinstall", "ios", 2),
      ld_row(@busy.id, "time_spent", "ios", 3, engagement: 13_000),
      ld_row(@busy.id, "reactivation", "ios", 4),
      ld_row(@busy.id, "app_open", "ios", 90),
      ld_row(@busy.id, "user_referred", "ios", 10),
      # event-time attribution: same link, rows recorded under @other on android
      ld_row(@other.id, "view", "android", 7)
    ])
  end

  teardown do
    Rails.application.config.clickhouse_read_enabled = @original_read
    Rails.application.config.clickhouse_analytics_rollups_read_enabled = @original_rollups
    Rails.application.config.revenue_reads_from_ledger = @original_ledger
  end

  test "metrics come from the rollup and revenue from PG" do
    entry = query.call.find { |c| c.id == @busy.id }

    assert_not_nil entry
    assert_equal 100, entry.total_views.to_i, "views must come from CH (PG says 2)"
    assert_equal 50, entry.total_opens.to_i
    assert_equal 10, entry.total_installs.to_i
    assert_equal 2, entry.total_reinstalls.to_i
    assert_equal 13_000, entry.total_time_spent.to_i
    assert_equal 4, entry.total_reactivations.to_i
    assert_equal 90, entry.total_app_opens.to_i
    assert_equal 10, entry.total_user_referred.to_i
    assert_equal 2998, entry.total_revenue.to_i, "revenue (999 + 1999) still sourced from PG"
  end

  test "campaigns without activity stay visible with zeroed metrics" do
    entry = query.call.find { |c| c.id == @quiet.id }

    assert_not_nil entry
    assert_equal 0, entry.total_views.to_i
    assert_equal 0, entry.total_revenue.to_i
  end

  test "metric sort orders by the CH totals with zero campaigns trailing on desc" do
    ids = query(sort_by: "views", ascending: false).call.map(&:id)

    assert_equal @busy.id, ids.first
    assert_equal @other.id, ids.second
    assert_operator ids.index(@quiet.id), :>, ids.index(@other.id)
  end

  test "metric sort asc puts zero campaigns first (Ruby sort mirrors PG COALESCE 0)" do
    ids = query(sort_by: "views", ascending: true).call.map(&:id)

    assert_equal @busy.id, ids.last
    assert_equal @other.id, ids[-2]
  end

  test "campaign field sort and name filter work on the CH path" do
    names = query(sort_by: "name", ascending: true, term: "CH ").call.map(&:name)

    assert_equal ["CH Busy Campaign", "CH Other Campaign"], names
  end

  test "archived filter applies" do
    ids = query(archived: true).call.map(&:id)

    assert_equal [campaigns(:archived_campaign).id], ids
  end

  test "platform filter applies to both CH metrics and PG revenue" do
    result = query(platform: "android", sort_by: "views", ascending: false).call
    top = result.first

    assert_equal @other.id, top.id
    assert_equal 7, top.total_views.to_i
    busy = result.find { |c| c.id == @busy.id }
    assert_equal 0, busy.total_views.to_i, "ios-only rows must not count under android"
    assert_equal 0, busy.total_revenue.to_i, "ios-only PG revenue must not count under android"
  end

  test "pagination slices the sorted set and keeps Kaminari meta" do
    page1 = query(sort_by: "views", ascending: false, per_page: 2, page: 1).call
    page2 = query(sort_by: "views", ascending: false, per_page: 2, page: 2).call

    assert_equal [@busy.id, @other.id], page1.map(&:id)
    assert_equal 5, page1.total_count, "all project-one campaigns"
    assert_equal 3, page1.total_pages
    assert_equal 1, page1.current_page
    assert_equal 2, page2.current_page
    assert_equal 2, page2.size
  end

  test "serializes like the PG path (totals + has_links pass through)" do
    serialized = CampaignSerializer.serialize(query.call)
    busy = serialized.find { |c| c["id"] == @busy.id }

    assert_equal 100, busy["total_views"].to_i
    assert_equal true, busy["has_links"]
    assert busy.key?("total_revenue")
  end

  test "falls back to PG when CH reads are disabled" do
    Rails.application.config.clickhouse_read_enabled = false # rollups flag stays ON

    entry = query.call.find { |c| c.id == @busy.id }

    assert_equal 2, entry.total_views.to_i, "PG fallback must serve PG sums, not zeros"
    assert_equal 2998, entry.total_revenue.to_i
  end

  test "PG path overlays ledger revenue when CH reads are disabled" do
    Rails.application.config.clickhouse_read_enabled = false # incident scenario
    original = Rails.application.config.revenue_reads_from_ledger
    Rails.application.config.revenue_reads_from_ledger = true
    PurchaseEvent.delete_all # fixture rows persist across classes
    pe = PurchaseEvent.create!(
      project: @project, link_id: @link.id, event_type: "buy", usd_price_cents: 6161,
      purchase_type: "one_time", processed: true, date: Time.utc(2026, 3, 1, 12),
      transaction_id: "csq_#{SecureRandom.hex(5)}"
    )
    pe.update_columns(revenue_platform: "ios")

    entry = query.call.find { |c| c.id == @busy.id }

    assert_equal 6161, entry.total_revenue.to_i, "PG path overlays ledger (stat says 2998)"
  ensure
    Rails.application.config.revenue_reads_from_ledger = original
  end

  test "ledger flag sources campaign revenue from purchase_events" do
    original = Rails.application.config.revenue_reads_from_ledger
    Rails.application.config.revenue_reads_from_ledger = true
    PurchaseEvent.delete_all # fixture rows persist across classes
    pe = PurchaseEvent.create!(
      project: @project, link_id: @link.id, event_type: "buy", usd_price_cents: 7777,
      purchase_type: "one_time", processed: true, date: Time.utc(2026, 3, 1, 12),
      transaction_id: "csq_#{SecureRandom.hex(5)}"
    )
    pe.update_columns(revenue_platform: "ios")

    entry = query.call.find { |c| c.id == @busy.id }

    assert_equal 7777, entry.total_revenue.to_i, "ledger-sourced (stat tables say 2998)"
  ensure
    Rails.application.config.revenue_reads_from_ledger = original
  end

  private

  def query(overrides = {})
    defaults = { start_date: "2026-03-01", end_date: "2026-03-02", page: 1, per_page: 20 }
    CampaignStatisticsQuery.new(project: @project, params: defaults.merge(overrides))
  end

  def ld_row(campaign_id, event_type, platform, cnt, engagement: 0)
    { project_id: @project.id, link_id: @link.id, campaign_id: campaign_id,
      event_date: "2026-03-01", event_type: event_type, platform: platform,
      cnt: cnt, total_engagement_time: engagement }
  end

  def insert_link_daily(rows)
    Clickhouse.with { |conn| conn.insert("link_daily", rows) }
  end
end
