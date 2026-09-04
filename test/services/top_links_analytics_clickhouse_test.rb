# frozen_string_literal: true

require "test_helper"

# CH-path parity for TopLinksAnalytics: same data + expectations as the PG test,
# but served from the link_metrics_daily rollup with the rollups-read flag ON.
class TopLinksAnalyticsClickhouseTest < ActiveSupport::TestCase
  include ClickhouseTestHelper

  fixtures :projects, :instances, :domains, :links, :redirect_configs

  setup do
    skip_unless_clickhouse!
    truncate_clickhouse_tables
    @project = projects(:one)
    @pid = @project.id
    @basic_link = links(:basic_link)

    @original_read = Rails.application.config.clickhouse_read_enabled
    @original_rollups = Rails.application.config.clickhouse_analytics_rollups_read_enabled
    Rails.application.config.clickhouse_read_enabled = true
    Rails.application.config.clickhouse_analytics_rollups_read_enabled = true

    @second_link = Link.create!(
      domain: domains(:one), redirect_config: redirect_configs(:one),
      path: "ch-second-#{SecureRandom.hex(4)}", active: true,
      sdk_generated: false, data: "[]", generated_from_platform: "android"
    )

    insert_link_metrics([
      row(@basic_link.id, Date.new(2026, 3, 1), "ios", views: 100, opens: 50, installs: 10, reinstalls: 2, time_spent: 5000, reactivations: 1),
      row(@basic_link.id, Date.new(2026, 3, 2), "ios", views: 200, opens: 80, installs: 20, reinstalls: 5, time_spent: 8000, reactivations: 3),
      row(@second_link.id, Date.new(2026, 3, 1), "android", views: 50, opens: 25, installs: 5, reinstalls: 1, time_spent: 2000, reactivations: 0)
    ])
  end

  teardown do
    Rails.application.config.clickhouse_read_enabled = @original_read
    Rails.application.config.clickhouse_analytics_rollups_read_enabled = @original_rollups
  end

  test "ranks links by installs descending from the CH rollup" do
    result = call

    assert_equal 2, result.size
    assert_equal 30, result.first[:installs]
    assert_equal 5, result.last[:installs]
  end

  test "aggregates each metric across days, matching PG semantics" do
    entry = call.find { |r| r["id"] == @basic_link.id }

    assert_equal 300, entry[:views]
    assert_equal 130, entry[:opens]
    assert_equal 30, entry[:installs]
    assert_equal 7, entry[:reinstalls]
    assert_equal 4, entry[:reactivations]
    assert_equal 13_000, entry[:time_spent]
    assert_equal @basic_link.id, entry["id"]
  end

  test "respects the limit parameter" do
    result = call(limit: 1)

    assert_equal 1, result.size
    assert_equal 30, result.first[:installs]
  end

  test "excludes sdk_generated links even when they dominate the rollup" do
    sdk_link = Link.create!(
      domain: domains(:one), redirect_config: redirect_configs(:one),
      path: "ch-sdk-#{SecureRandom.hex(4)}", active: true, sdk_generated: true,
      data: "[]", generated_from_platform: "ios"
    )
    insert_link_metrics([row(sdk_link.id, Date.new(2026, 3, 1), "ios", installs: 9999, views: 9999)])

    ids = call.map { |r| r["id"] }

    assert_not_includes ids, sdk_link.id
  end

  test "platform filter scopes the CH aggregation" do
    android = call(platform: "android")

    assert_equal 1, android.size
    assert_equal @second_link.id, android.first["id"]
    assert_equal 5, android.first[:installs]
  end

  private

  def call(platform: nil, limit: 10)
    TopLinksAnalytics.new(
      project_id: @pid, platform: platform,
      start_time: "2026-03-01", end_time: "2026-03-02", limit: limit
    ).call
  end

  def row(link_id, date, platform, views: 0, opens: 0, installs: 0, reinstalls: 0, time_spent: 0, reactivations: 0)
    {
      project_id: @pid, link_id: link_id, event_date: date.to_s, platform: platform,
      views: views, opens: opens, installs: installs, reinstalls: reinstalls,
      time_spent: time_spent, reactivations: reactivations, app_opens: 0, user_referred: 0
    }
  end

  def insert_link_metrics(rows)
    Clickhouse.with { |conn| conn.insert("link_metrics_daily", rows) }
  end
end
