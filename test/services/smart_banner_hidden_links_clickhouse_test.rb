require "test_helper"

class SmartBannerHiddenLinksClickhouseTest < ActiveSupport::TestCase
  include ClickhouseTestHelper
  include SmartBannerTestHelper

  fixtures :projects, :instances, :domains, :links, :link_daily_statistics, :redirect_configs, :campaigns

  setup do
    skip_unless_clickhouse!
    truncate_clickhouse_tables
    @project = projects(:one)
    @flags = %i[clickhouse_read_enabled clickhouse_analytics_rollups_read_enabled
                clickhouse_link_dimensions_read_enabled clickhouse_write_enabled revenue_reads_from_ledger]
             .index_with { |f| Rails.application.config.public_send(f) }
    Rails.application.config.clickhouse_read_enabled = true
    Rails.application.config.clickhouse_analytics_rollups_read_enabled = true
    Rails.application.config.clickhouse_write_enabled = true
    Rails.application.config.revenue_reads_from_ledger = false

    banner = create_test_banner(@project)
    @page_link = SmartBannerLinkService.fetch(banner, page_path: "/p", data: {})
    @banner_link_ids = [banner.default_link_id, @page_link.id]
    # Banner links get the most installs, so they would sort first if they leaked.
    Clickhouse.with do |conn|
      conn.insert("link_metrics_daily", @banner_link_ids.map { |id| metrics_row(id, installs: 1_000) } +
                                        [metrics_row(links(:basic_link).id, installs: 10)])
    end
    LinkDimensionSyncService.sync_all(Link.where(domain_id: @project.domain.id).includes(:domain))
    @visible = Link.where(domain_id: @project.domain.id, active: true).where.not(id: @banner_link_ids).count
  end

  teardown do
    @flags&.each { |flag, value| Rails.application.config.public_send("#{flag}=", value) }
  end

  test "field sort, id-list metric sort and dimension metric sort all leave banner links out" do
    paths = {
      "field sort" => -> { query(sort_by: "created_at").call },
      "id-list metric sort" => -> { query(sort_by: "installs").call },
      "dimension metric sort" => -> { with_dimensions { query(sort_by: "installs").call } }
    }

    paths.each do |name, run|
      result = run.call
      ids = result[:links].map { |l| l["id"] }

      assert_empty ids & @banner_link_ids, "#{name} leaked a banner link"
      assert_equal @visible, result[:meta][:total_entries], "#{name} counted banner links"
    end
  end

  test "the dimension metric sort path executes ClickHouse's dimension query, not a fallback" do
    original = ClickhouseReadService.method(:link_page_from_dimensions)
    captured = nil
    spy = ->(*args, **kwargs) { captured = original.call(*args, **kwargs) }

    with_dimensions { ClickhouseReadService.stub(:link_page_from_dimensions, spy) { query(sort_by: "installs").call } }

    assert_not_nil captured, "dimension metric sort must hit link_page_from_dimensions directly, not silently fall back"
    assert_empty captured[:rows].map { |r| r["link_id"].to_i } & @banner_link_ids
  end

  test "a direct link_id lookup still returns a banner link on the id-list and dimension paths" do
    banner_id = @banner_link_ids.first

    id_list = query(sort_by: "installs", link_id: banner_id).call
    assert_equal [banner_id], id_list[:links].map { |l| l["id"] }

    dimension = with_dimensions { query(sort_by: "installs", link_id: banner_id).call }
    assert_equal [banner_id], dimension[:links].map { |l| l["id"] }
  end

  test "the dimension path pages exactly like the id-list path" do
    (1..2).each do |page|
      params = { sort_by: "installs", per_page: 1, page: page }
      assert_equal query(params).call, with_dimensions { query(params).call }, "page #{page} diverged"
    end
  end

  test "banner link activity still counts in project totals" do
    @ch_auto_rebuild_breakdowns = true
    now = Time.current.utc.strftime("%Y-%m-%d %H:%M:%S.%3N")
    insert_ch_events([
      { event_id: "sb_total_install", project_id: @project.id, event_type: Grovs::Events::INSTALL,
        link_id: @page_link.id, visitor_id: 41_001, platform: "ios", created_at: now }
    ])

    metrics = Analytics::OverviewStatsService.key_metrics(
      @project.id, start_date: Date.current - 1, end_date: Date.current
    )[:metrics]

    assert_equal 1, metrics[:installs]
    assert_equal 1, metrics[:link_driven_installs]
  ensure
    Rails.cache.clear
  end

  private

  def query(overrides = {})
    defaults = { start_date: "2026-03-01", end_date: "2026-03-02", page: 1, per_page: 20,
                 sort_by: "installs", ascendent: false, active: true }
    LinkStatisticsQuery.new(params: defaults.merge(overrides), project: @project)
  end

  def with_dimensions
    Rails.application.config.clickhouse_link_dimensions_read_enabled = true
    yield
  ensure
    Rails.application.config.clickhouse_link_dimensions_read_enabled = false
  end

  def metrics_row(link_id, **metrics)
    { project_id: @project.id, link_id: link_id, event_date: "2026-03-01", platform: "ios",
      views: 0, opens: 0, installs: 0, reinstalls: 0, time_spent: 0,
      reactivations: 0, app_opens: 0, user_referred: 0 }.merge(metrics)
  end
end
