# frozen_string_literal: true

require "test_helper"

class RevenueMetricsQueryClickhouseTest < ActiveSupport::TestCase
  include ClickhouseTestHelper

  fixtures :instances, :projects, :devices, :visitors, :purchase_events,
           :in_app_products, :in_app_product_daily_statistics

  RANGE = { start_date: Date.new(2026, 3, 1), end_date: Date.new(2026, 3, 31) }.freeze

  setup do
    @project = projects(:one)
    # Rows from other classes survive in the worker's DB; start from a known state.
    VisitorDailyStatistic.where(project_id: @project.id).delete_all
    VisitorDailyStatistic.create!(project_id: @project.id, visitor: visitors(:ios_visitor),
                                  event_date: RANGE[:start_date], platform: "ios", views: 1)
    VisitorDailyStatistic.create!(project_id: @project.id, visitor: visitors(:android_visitor),
                                  event_date: RANGE[:start_date], platform: "android", views: 1)
  end

  def arpu(platform: nil)
    RevenueMetricsQuery.new(project_id: @project.id, product: nil, platform: platform, **RANGE)
                       .with_arpu.first&.fetch("arpu_usd_cents")
  end

  test "a Time end_date still bounds the last day, not the last second" do
    query = RevenueMetricsQuery.new(project_id: @project.id, product: nil,
                                    start_date: Time.utc(2026, 3, 1, 9, 30),
                                    end_date: Time.utc(2026, 3, 31, 9, 30))

    assert_equal Date.new(2026, 3, 31), query.instance_variable_get(:@end_date)
    assert_equal Date.new(2026, 3, 1), query.instance_variable_get(:@start_date)
  end

  test "reads the real rollup end to end" do
    skip_unless_clickhouse!
    # billing_active_visitors also needs the base read flag, which defaults to false.
    Rails.application.config.clickhouse_read_enabled = true
    Rails.application.config.clickhouse_analytics_rollups_read_enabled = true
    insert_ch_events([71, 72, 73].map do |vid|
      { project_id: @project.id, visitor_id: vid, device_id: vid, event_type: Grovs::Events::OPEN,
        platform: "ios", created_at: "2026-03-05 09:00:00.000" }
    end)
    ClickhouseRollupRebuildService.rebuild_partition(:billing, "202603")

    revenue = RevenueMetricsQuery.new(project_id: @project.id, product: nil, **RANGE)
                                 .call.first&.fetch("total_revenue_usd_cents").to_f

    assert_in_delta (revenue / 3).round(2), arpu, 0.01
  end

  test "flag OFF divides by the Postgres visitor count and never asks ClickHouse" do
    Rails.application.config.clickhouse_analytics_rollups_read_enabled = false
    revenue = RevenueMetricsQuery.new(project_id: @project.id, product: nil, **RANGE)
                                 .call.first&.fetch("total_revenue_usd_cents").to_f

    ClickhouseReadService.stub(:billing_active_visitors, ->(*, **) { raise "must not be called" }) do
      assert_in_delta (revenue / 2).round(2), arpu, 0.01
    end
  end

  test "a real ClickHouse zero is used, not treated as a fallback" do
    Rails.application.config.clickhouse_analytics_rollups_read_enabled = true

    ClickhouseReadService.stub(:billing_active_visitors, ->(*, **) { 0 }) do
      assert_equal 0.0, arpu, "PG has 2 visitors; a genuine CH zero must not fall through to it"
    end
  end

  test "flag ON divides by the ClickHouse visitor count" do
    Rails.application.config.clickhouse_analytics_rollups_read_enabled = true
    revenue = RevenueMetricsQuery.new(project_id: @project.id, product: nil, **RANGE)
                                 .call.first&.fetch("total_revenue_usd_cents").to_f

    ClickhouseReadService.stub(:billing_active_visitors, ->(*, **) { 5 }) do
      assert_in_delta (revenue / 5).round(2), arpu, 0.01
    end
  end

  test "a platform filter uses the per-platform ClickHouse reader" do
    Rails.application.config.clickhouse_analytics_rollups_read_enabled = true
    seen = nil

    capture = lambda do |_pid, **kw|
      seen = kw[:platforms]
      4
    end
    ClickhouseReadService.stub(:unique_visitors_by_platform, capture) { arpu(platform: "ios") }

    assert_equal ["ios"], seen
  end

  test "an unavailable ClickHouse falls back to Postgres, never to a zero denominator" do
    Rails.application.config.clickhouse_analytics_rollups_read_enabled = true
    revenue = RevenueMetricsQuery.new(project_id: @project.id, product: nil, **RANGE)
                                 .call.first&.fetch("total_revenue_usd_cents").to_f

    ClickhouseReadService.stub(:billing_active_visitors, ->(*, **) { nil }) do
      assert_in_delta (revenue / 2).round(2), arpu, 0.01
      assert_operator arpu, :>, 0
    end
  end
end
