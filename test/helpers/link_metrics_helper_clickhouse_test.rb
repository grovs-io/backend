# frozen_string_literal: true

require "test_helper"

class LinkMetricsHelperClickhouseTest < ActiveSupport::TestCase
  include LinkMetricsHelper
  include ClickhouseTestHelper

  fixtures :instances, :projects, :domains, :links, :redirect_configs

  setup do
    skip_unless_clickhouse!
    truncate_clickhouse_tables
    @project = projects(:one)
    @link = Link.create!(
      domain: domains(:one), redirect_config: redirect_configs(:one),
      path: "ch-csv-#{SecureRandom.hex(4)}", title: "CH CSV Link",
      generated_from_platform: "ios", sdk_generated: false, active: true
    )

    @original_read = Rails.application.config.clickhouse_read_enabled
    @original_rollups = Rails.application.config.clickhouse_analytics_rollups_read_enabled
    Rails.application.config.clickhouse_read_enabled = true
    Rails.application.config.clickhouse_analytics_rollups_read_enabled = true

    # PG values deliberately differ from CH so the serving store is provable
    create_pg_stat(@link, Date.new(2026, 3, 1),
                   views: 1, opens: 1, installs: 1, reinstalls: 1, reactivations: 1, time_spent: 1)
    insert_link_metrics([
      ch_row(@link.id, Date.new(2026, 3, 1), views: 100, opens: 50, installs: 10, reinstalls: 2, reactivations: 1, time_spent: 5000),
      ch_row(@link.id, Date.new(2026, 3, 2), views: 200, opens: 80, installs: 20, reinstalls: 5, reactivations: 3, time_spent: 8000)
    ])
  end

  teardown do
    Rails.application.config.clickhouse_read_enabled = @original_read
    Rails.application.config.clickhouse_analytics_rollups_read_enabled = @original_rollups
  end

  test "flag on serves the six exported counts from the CH rollup" do
    row = export_row

    assert_equal "300", row["View"]
    assert_equal "130", row["Open"]
    assert_equal "30", row["Install"]
    assert_equal "7", row["Reinstall"]
    assert_equal "4", row["Reactivation"]
    assert_equal "13000", row["Time Spent"]
  end

  test "CSV contract is byte-identical in shape on the CH path" do
    rows = CSV.parse(export_csv, headers: true)

    assert_equal [
      "Link ID", "Name", "Title", "Subtitle", "Updated At",
      "Generated From Platform", "SDK Generated", "Tags", "Active",
      "Access Path", "View", "Open", "Install", "Reinstall",
      "Reactivation", "Avg Engagement Time", "Time Spent", "Data", "Campaign"
    ], rows.headers
    assert_equal "0.0", rows.first["Avg Engagement Time"]
  end

  test "flag off leaves the PG path untouched" do
    Rails.application.config.clickhouse_analytics_rollups_read_enabled = false

    row = export_row

    assert_equal "1", row["View"]
    assert_equal "1", row["Install"]
  end

  test "nil reader result falls back to PG" do
    ClickhouseReadService.stub(:link_metrics_by_id, nil) do
      row = export_row

      assert_equal "1", row["View"]
      assert_equal "1", row["Time Spent"]
    end
  end

  test "CH success with no rows for a link yields zero defaults, not PG fallback" do
    bare_link = Link.create!(
      domain: domains(:one), redirect_config: redirect_configs(:one),
      path: "ch-bare-#{SecureRandom.hex(4)}", generated_from_platform: "ios",
      sdk_generated: false, active: true
    )
    create_pg_stat(bare_link, Date.new(2026, 3, 1), views: 42)

    rows = CSV.parse(export_csv(links: [bare_link]), headers: true)

    assert_equal "0", rows.first["View"]
  end

  test "date range bounds the CH aggregation" do
    row = export_row(end_date: Date.new(2026, 3, 1))

    assert_equal "100", row["View"]
    assert_equal "10", row["Install"]
  end

  private

  def export_csv(links: [@link], start_date: Date.new(2026, 3, 1), end_date: Date.new(2026, 3, 2))
    export_links_metrics_to_csv(
      links: links, project_id: @project.id, start_date: start_date, end_date: end_date
    )
  end

  def export_row(**kwargs)
    CSV.parse(export_csv(**kwargs), headers: true).first
  end

  def create_pg_stat(link, date, metrics = {})
    LinkDailyStatistic.create!(
      link: link, project_id: @project.id, event_date: date, platform: "ios",
      views: metrics[:views] || 0, opens: metrics[:opens] || 0,
      installs: metrics[:installs] || 0, reinstalls: metrics[:reinstalls] || 0,
      reactivations: metrics[:reactivations] || 0, time_spent: metrics[:time_spent] || 0,
      app_opens: 0, user_referred: 0, revenue: 0
    )
  end

  def ch_row(link_id, date, views: 0, opens: 0, installs: 0, reinstalls: 0, reactivations: 0, time_spent: 0)
    {
      project_id: @project.id, link_id: link_id, event_date: date.to_s, platform: "ios",
      views: views, opens: opens, installs: installs, reinstalls: reinstalls,
      time_spent: time_spent, reactivations: reactivations, app_opens: 0, user_referred: 0
    }
  end

  def insert_link_metrics(rows)
    Clickhouse.with { |conn| conn.insert("link_metrics_daily", rows) }
  end
end
