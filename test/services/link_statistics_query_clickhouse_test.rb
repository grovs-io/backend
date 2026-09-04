# frozen_string_literal: true

require "test_helper"

# CH-path parity for LinkStatisticsQuery (search_v2). Link-field / default sorts
# paginate on `links` and read covered metrics from link_metrics_daily; metric
# sorts paginate in the rollup itself with zero-activity links appended last;
# revenue serves from the purchase ledger when REVENUE_READS_FROM_LEDGER is on,
# else the PG stat tables.
class LinkStatisticsQueryClickhouseTest < ActiveSupport::TestCase
  include ClickhouseTestHelper

  fixtures :projects, :instances, :domains, :links, :link_daily_statistics, :redirect_configs

  setup do
    skip_unless_clickhouse!
    truncate_clickhouse_tables
    @project = projects(:one)
    @basic_link = links(:basic_link)

    @original_read = Rails.application.config.clickhouse_read_enabled
    @original_rollups = Rails.application.config.clickhouse_analytics_rollups_read_enabled
    Rails.application.config.clickhouse_read_enabled = true
    Rails.application.config.clickhouse_analytics_rollups_read_enabled = true
    # Pin the ledger flag so a CI env with REVENUE_READS_FROM_LEDGER=true can't flip legacy assertions.
    @original_ledger = Rails.application.config.revenue_reads_from_ledger
    Rails.application.config.revenue_reads_from_ledger = false

    # Mirror the basic_link link_daily_statistics fixture rows into the rollup.
    insert_link_metrics([
      row(@basic_link.id, "2026-03-01", "ios", views: 100, opens: 50, installs: 10, reinstalls: 2, time_spent: 5000, reactivations: 1, app_opens: 30, 
user_referred: 3),
      row(@basic_link.id, "2026-03-02", "ios", views: 200, opens: 80, installs: 20, reinstalls: 5, time_spent: 8000, reactivations: 3, app_opens: 60, 
user_referred: 7)
    ])
  end

  teardown do
    Rails.application.config.clickhouse_read_enabled = @original_read
    Rails.application.config.clickhouse_analytics_rollups_read_enabled = @original_rollups
    Rails.application.config.revenue_reads_from_ledger = @original_ledger
  end

  test "default-sort CH path aggregates covered metrics from the rollup and revenue from PG" do
    link = query.call[:links].find { |l| l["id"] == @basic_link.id }

    assert_not_nil link
    assert_equal 300, link["total_views"]
    assert_equal 130, link["total_opens"]
    assert_equal 30, link["total_installs"]
    assert_equal 7, link["total_reinstalls"]
    assert_equal 13_000, link["total_time_spent"]
    assert_equal 4, link["total_reactivations"]
    assert_equal 90, link["total_app_opens"]
    assert_equal 10, link["total_user_referred"]
    assert_equal 2998, link["total_revenue"], "revenue (999 + 1999) still sourced from PG"
  end

  test "CH path returns pagination meta and slim link fields" do
    result = query.call

    assert result[:meta].key?(:total_entries)
    assert result[:meta].key?(:total_pages)
    link = result[:links].find { |l| l["id"] == @basic_link.id }
    assert_equal @basic_link.path, link["path"]
    assert_not link.key?("image"), "slim serialization omits image"
  end

  # Project one's active links: basic_link (CH rows), campaign_link (CH rows added
  # per-test), no_custom_redirect_link ("standard", NO CH rows — the zero tail,
  # despite having PG stats with installs=2).

  test "metric sort orders by the rollup, not PG, with revenue from PG" do
    # CH says campaign_link has more installs than basic_link; PG says the opposite (15 vs 30).
    insert_link_metrics([row(links(:campaign_link).id, "2026-03-01", "ios", installs: 99)])

    result = query(sort_by: "installs", ascendent: false).call
    ids = result[:links].map { |l| l["id"] }

    assert_equal [links(:campaign_link).id, @basic_link.id, links(:no_custom_redirect_link).id], ids
    basic = result[:links].find { |l| l["id"] == @basic_link.id }
    assert_equal 30, basic["total_installs"]
    assert_equal 2998, basic["total_revenue"], "revenue still sourced from PG"
    standard = result[:links].last
    assert_equal 0, standard["total_installs"], "zero tail is CH-sourced (PG stats say 2)"
  end

  test "asc metric sort keeps zero-activity links last" do
    insert_link_metrics([row(links(:campaign_link).id, "2026-03-01", "ios", installs: 99)])

    ids = query(sort_by: "installs", ascendent: true).call[:links].map { |l| l["id"] }

    assert_equal [@basic_link.id, links(:campaign_link).id, links(:no_custom_redirect_link).id], ids,
                 "active links ascend; the no-activity link stays last (PG put it first)"
  end

  # A link with rows for OTHER metrics is still zero for the sorted one; it must tail with
  # the no-rows link, not sort ahead of links that actually have the metric.
  test "links with rows but zero of the sorted metric tail like no-rows links" do
    insert_link_metrics([row(links(:campaign_link).id, "2026-03-01", "ios", views: 42)])

    ids = query(sort_by: "installs", ascendent: true).call[:links].map { |l| l["id"] }

    assert_equal @basic_link.id, ids.first, "the only link with installs must lead an ASC sort"
    assert_equal [links(:campaign_link).id, links(:no_custom_redirect_link).id].sort,
                 ids.drop(1).sort, "both zero-install links tail, regardless of other rows"
  end

  test "a tail link keeps the metrics it does have" do
    insert_link_metrics([row(links(:campaign_link).id, "2026-03-01", "ios", views: 42)])

    result = query(sort_by: "installs", ascendent: true).call
    tail = result[:links].find { |l| l["id"] == links(:campaign_link).id }

    assert_equal 0, tail["total_installs"], "zero for the sorted metric"
    assert_equal 42, tail["total_views"], "but its real views must survive the tail"
  end

  test "metric-sort pages straddle into the zero tail with stable meta" do
    insert_link_metrics([row(links(:campaign_link).id, "2026-03-01", "ios", installs: 99)])

    pages = (1..3).map { |p| query(sort_by: "installs", ascendent: false, per_page: 1, page: p).call }

    assert_equal [links(:campaign_link).id], pages[0][:links].map { |l| l["id"] }
    assert_equal [@basic_link.id], pages[1][:links].map { |l| l["id"] }
    assert_equal [links(:no_custom_redirect_link).id], pages[2][:links].map { |l| l["id"] }
    pages.each do |page|
      assert_equal 3, page[:meta][:total_entries]
      assert_equal 3, page[:meta][:total_pages]
    end
  end

  test "all: true metric sort returns the full CH-ordered set in one page" do
    insert_link_metrics([row(links(:campaign_link).id, "2026-03-01", "ios", installs: 99)])

    result = query(sort_by: "installs", ascendent: false, all: true).call

    assert_equal [links(:campaign_link).id, @basic_link.id, links(:no_custom_redirect_link).id],
                 result[:links].map { |l| l["id"] }
    assert_equal 1, result[:meta][:total_pages]
    assert_equal 3, result[:meta][:per_page]
  end

  test "unsortable metric raises instead of silently falling back" do
    assert_raises(ArgumentError) do
      ClickhouseReadService.link_metrics_sorted_page(
        @project.id, link_ids: [1], metric: "revenue", direction: "desc",
        start_date: "2026-03-01", end_date: "2026-03-02", limit: 1, offset: 0
      )
    end
  end

  test "metric sort falls back to PG when the candidate id set exceeds the cap" do
    q = query(sort_by: "installs", ascendent: true)

    result = q.stub(:metric_sort_id_cap, 1) { q.call }

    ids = result[:links].map { |l| l["id"] }
    assert_equal links(:no_custom_redirect_link).id, ids.first, "PG ASC puts the 2-install link first"
    assert_equal 3, result[:meta][:total_entries]
  end

  test "metric sort falls back to the PG aggregate path when CH reads are disabled" do
    Rails.application.config.clickhouse_read_enabled = false # rollups flag stays ON

    result = query(sort_by: "installs", ascendent: false).call

    assert_equal @basic_link.id, result[:links].first["id"], "PG sums (30 installs) drive the order"
    assert_equal 30, result[:links].first["total_installs"]
    assert_equal 2998, result[:links].first["total_revenue"]
  end

  test "falls back to PG covered metrics when CH reads are disabled (no zeros)" do
    Rails.application.config.clickhouse_read_enabled = false # rollups flag stays ON

    link = query.call[:links].find { |l| l["id"] == @basic_link.id }

    assert_equal 300, link["total_views"], "CH unavailable must fall back to PG, not return zeros"
    assert_equal 30, link["total_installs"]
    assert_equal 2998, link["total_revenue"]
  end

  test "ads_platform filter applies on the CH path" do
    @basic_link.update!(ads_platform: "google")

    result = query(ads_platform: "google").call

    assert_equal [@basic_link.id], result[:links].map { |l| l["id"] }
    assert_equal 300, result[:links].first["total_views"]
    assert_equal 0, query(ads_platform: "meta").call[:links].length
  end

  test "revenue-sort (uncovered by rollup) stays on PG and orders correctly" do
    result = query(sort_by: "revenue", ascendent: false).call
    top = result[:links].first

    assert_equal @basic_link.id, top["id"], "basic_link has the most revenue"
    assert_equal 2998, top["total_revenue"]
  end

  # --- REVENUE_READS_FROM_LEDGER ---

  test "ledger flag routes page revenue and revenue sort through purchase_events" do
    with_ledger_flag do
      # Ledger: campaign_link earns MORE than basic_link (stat tables say the opposite).
      ledger_purchase(links(:campaign_link), 5000)
      ledger_purchase(@basic_link, 100)

      result = query(sort_by: "revenue", ascendent: false).call
      ids = result[:links].map { |l| l["id"] }

      assert_equal links(:campaign_link).id, ids.first, "ledger cents decide the order (stats say basic_link)"
      assert_equal 5000, result[:links].first["total_revenue"], "ledger-sourced value"
      assert_equal links(:no_custom_redirect_link).id, ids.last, "zero-revenue links last"

      asc_ids = query(sort_by: "revenue", ascendent: true).call[:links].map { |l| l["id"] }
      assert_equal links(:no_custom_redirect_link).id, asc_ids.last, "zero tail stays last on ASC too"
      assert_equal @basic_link.id, asc_ids.first
    end
  end

  test "ledger revenue sort and value overlay survive CH reads being disabled" do
    Rails.application.config.clickhouse_read_enabled = false # incident scenario
    with_ledger_flag do
      ledger_purchase(links(:campaign_link), 5000)
      ledger_purchase(@basic_link, 100)

      sorted = query(sort_by: "revenue", ascendent: false).call
      assert_equal links(:campaign_link).id, sorted[:links].first["id"], "ledger sorts without CH"
      assert_equal 5000, sorted[:links].first["total_revenue"]

      listed = query(sort_by: "created_at").call[:links].find { |l| l["id"] == @basic_link.id }
      assert_equal 100, listed["total_revenue"], "PG-path field sort overlays ledger revenue (stat says 2998)"
    end
  end

  test "revenue ties break by id ascending in both directions" do
    with_ledger_flag do
      ledger_purchase(links(:campaign_link), 500)
      ledger_purchase(@basic_link, 500)
      low, high = [@basic_link.id, links(:campaign_link).id].minmax

      desc_ids = query(sort_by: "revenue", ascendent: false).call[:links].map { |l| l["id"] }
      asc_ids = query(sort_by: "revenue", ascendent: true).call[:links].map { |l| l["id"] }

      assert_equal [low, high], desc_ids.first(2)
      assert_equal [low, high], asc_ids.first(2)
    end
  end

  test "ledger flag off keeps stat-table revenue sorting" do
    result = query(sort_by: "revenue", ascendent: false).call

    assert_equal @basic_link.id, result[:links].first["id"]
    assert_equal 2998, result[:links].first["total_revenue"]
  end

  private

  def with_ledger_flag
    original = Rails.application.config.revenue_reads_from_ledger
    Rails.application.config.revenue_reads_from_ledger = true
    PurchaseEvent.delete_all # fixture rows persist across classes
    yield
  ensure
    Rails.application.config.revenue_reads_from_ledger = original
  end

  def ledger_purchase(link, cents)
    pe = PurchaseEvent.create!(
      project: @project, link_id: link.id, event_type: "buy", usd_price_cents: cents,
      purchase_type: "one_time", processed: true, date: Time.utc(2026, 3, 1, 12),
      transaction_id: "lsq_#{SecureRandom.hex(5)}"
    )
    pe.update_columns(revenue_platform: "ios")
    pe
  end

  def query(overrides = {})
    defaults = {
      start_date: "2026-03-01", end_date: "2026-03-02",
      page: 1, per_page: 20, sort_by: "created_at", ascendent: false, active: true
    }
    LinkStatisticsQuery.new(params: defaults.merge(overrides), project: @project)
  end

  def row(link_id, date, platform, **metrics)
    {
      project_id: @project.id, link_id: link_id, event_date: date, platform: platform,
      views: 0, opens: 0, installs: 0, reinstalls: 0, time_spent: 0,
      reactivations: 0, app_opens: 0, user_referred: 0
    }.merge(metrics)
  end

  def insert_link_metrics(rows)
    Clickhouse.with { |conn| conn.insert("link_metrics_daily", rows) }
  end
end
