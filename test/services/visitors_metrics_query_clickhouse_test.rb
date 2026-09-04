# frozen_string_literal: true

require "test_helper"

# CH-gated dual-read for the payment-screen visitor series (Phase 1a). Flag OFF must keep
# reading project_daily_active_users; flag ON reads the CH billing rollup, and a CH failure
# falls back rather than serving zeros.
class VisitorsMetricsQueryClickhouseTest < ActiveSupport::TestCase
  include ClickhouseTestHelper

  fixtures :projects, :instances

  RANGE = { start_date: "2026-03-01", end_date: "2026-03-03" }.freeze

  setup do
    skip_unless_clickhouse!
    @project = projects(:one)
    @pid = @project.id
    ProjectDailyActiveUser.create!(project: @project, event_date: Date.new(2026, 3, 1), active_users: 11)
    ProjectDailyActiveUser.create!(project: @project, event_date: Date.new(2026, 3, 2), active_users: 22)
  end

  def values(**range)
    VisitorsMetricsQuery.new(project_ids: [@pid], **RANGE.merge(range)).call[:metrics_values]
  end

  test "flag OFF reads project_daily_active_users" do
    Rails.application.config.clickhouse_analytics_rollups_read_enabled = false

    assert_equal [11, 22, 0], values.values_at("2026-03-01", "2026-03-02", "2026-03-03")
  end

  test "flag ON reads the ClickHouse series and still zero-fills the gap" do
    Rails.application.config.clickhouse_analytics_rollups_read_enabled = true
    series = { Date.new(2026, 3, 1) => 7, Date.new(2026, 3, 3) => 9 }

    ClickhouseReadService.stub(:active_visitors_series, ->(*, **) { series }) do
      assert_equal [7, 0, 9], values.values_at("2026-03-01", "2026-03-02", "2026-03-03")
    end
  end

  test "an unavailable ClickHouse read falls back to Postgres, never to zeros" do
    Rails.application.config.clickhouse_analytics_rollups_read_enabled = true

    ClickhouseReadService.stub(:active_visitors_series, ->(*, **) { nil }) do
      assert_equal [11, 22, 0], values.values_at("2026-03-01", "2026-03-02", "2026-03-03")
    end
  end

  test "reads the real rollup end to end" do
    Rails.application.config.clickhouse_analytics_rollups_read_enabled = true
    insert_ch_events([
      { project_id: @pid, visitor_id: 91, device_id: 91, event_type: Grovs::Events::OPEN,
        platform: "ios", created_at: "2026-03-01 09:00:00.000" },
      { project_id: @pid, visitor_id: 92, device_id: 92, event_type: Grovs::Events::OPEN,
        platform: "ios", created_at: "2026-03-01 10:00:00.000" }
    ])
    ClickhouseRollupRebuildService.rebuild_partition(:billing, "202603")

    assert_equal 2, values["2026-03-01"]
  end
end
