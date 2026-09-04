# frozen_string_literal: true

require "test_helper"

class ActiveUsersReportClickhouseTest < ActiveSupport::TestCase
  include ClickhouseTestHelper
  include ChQueryCounter

  fixtures :instances, :projects, :visitors, :devices

  setup do
    skip_unless_clickhouse!
    @ch_auto_rebuild_breakdowns = true
    @project = projects(:one)
    @pid = @project.id

    @original_read = Rails.application.config.clickhouse_read_enabled
    @original_rollups = Rails.application.config.clickhouse_analytics_rollups_read_enabled
    Rails.application.config.clickhouse_read_enabled = true
    Rails.application.config.clickhouse_analytics_rollups_read_enabled = true

    # PG data deliberately different from CH so the serving store is provable:
    # PG says 1 visitor on May 1 only; CH says 2 visitors May 1 + 1 visitor May 2.
    VisitorDailyStatistic.create!(
      visitor: visitors(:ios_visitor), project_id: @pid,
      event_date: Date.new(2026, 5, 1), platform: "ios", views: 1
    )
    insert_ch_events([
      ch_event(visitors(:ios_visitor).id, "2026-05-01"),
      ch_event(visitors(:android_visitor).id, "2026-05-01"),
      ch_event(visitors(:ios_visitor).id, "2026-05-02")
    ])
  end

  teardown do
    Rails.application.config.clickhouse_read_enabled = @original_read
    Rails.application.config.clickhouse_analytics_rollups_read_enabled = @original_rollups
  end

  # ---------------------------------------------------------------------------
  # ClickhouseReadService.active_visitors_series
  # ---------------------------------------------------------------------------

  test "daily series returns Date-keyed distinct counts" do
    series = ClickhouseReadService.active_visitors_series(
      [@pid], start_date: Date.new(2026, 5, 1), end_date: Date.new(2026, 5, 31), grouping: :day
    )

    assert_equal({ Date.new(2026, 5, 1) => 2, Date.new(2026, 5, 2) => 1 }, series)
  end

  test "monthly series groups distinct visitors in CH, not summed dailies" do
    # ios_visitor active on 2 days of May must count once in the month
    series = ClickhouseReadService.active_visitors_series(
      [@pid], start_date: Date.new(2026, 5, 1), end_date: Date.new(2026, 5, 31), grouping: :month
    )

    assert_equal({ "2026-05" => 2 }, series)
  end

  test "series spanning months buckets each month separately" do
    insert_ch_events([ch_event(visitors(:android_visitor).id, "2026-06-03")])

    series = ClickhouseReadService.active_visitors_series(
      [@pid], start_date: Date.new(2026, 5, 1), end_date: Date.new(2026, 6, 30), grouping: :month
    )

    assert_equal({ "2026-05" => 2, "2026-06" => 1 }, series)
  end

  test "empty range returns empty hash, not nil" do
    series = ClickhouseReadService.active_visitors_series(
      [@pid], start_date: Date.new(2027, 1, 1), end_date: Date.new(2027, 1, 31), grouping: :day
    )

    assert_equal({}, series)
  end

  test "returns nil when reads disabled" do
    Rails.application.config.clickhouse_read_enabled = false

    series = ClickhouseReadService.active_visitors_series(
      [@pid], start_date: Date.new(2026, 5, 1), end_date: Date.new(2026, 5, 31), grouping: :day
    )

    assert_nil series
  end

  test "rejects unknown grouping" do
    assert_raises(ArgumentError) do
      ClickhouseReadService.active_visitors_series(
        [@pid], start_date: Date.new(2026, 5, 1), end_date: Date.new(2026, 5, 31), grouping: :week
      )
    end
  end

  # ---------------------------------------------------------------------------
  # ActiveUsersReport wiring
  # ---------------------------------------------------------------------------

  test "flag on serves the CSV from CH counts" do
    csv = report_csv

    assert_includes csv, "2026-05-01,2"
    assert_includes csv, "2026-05-02,1"
  end

  test "flag off serves the CSV from PG counts" do
    Rails.application.config.clickhouse_analytics_rollups_read_enabled = false

    csv = report_csv

    assert_includes csv, "2026-05-01,1"
    assert_includes csv, "2026-05-02,0"
  end

  test "nil reader result falls back to PG" do
    ClickhouseReadService.stub(:active_visitors_series, nil) do
      csv = report_csv

      assert_includes csv, "2026-05-01,1"
    end
  end

  test "monthly total in CSV uses CH monthly distincts" do
    csv = report_csv

    assert_includes csv, "2026-05,2"
  end

  test "range spanning months merges per-month reads without double counting" do
    insert_ch_events([ch_event(visitors(:android_visitor).id, "2026-06-03")])

    csv = ActiveUsersReport.new(
      project_ids: [@pid], start_date: Date.new(2026, 5, 1), end_date: Date.new(2026, 6, 30)
    ).call

    assert_includes csv, "2026-05-01,2"
    assert_includes csv, "2026-05-02,1"
    assert_includes csv, "2026-06-03,1"
    assert_includes csv, "2026-05,2"
    assert_includes csv, "2026-06,1"
    assert_includes csv, "Sum of Monthly Unique Active Users,3"
  end

  test "issues one CH read per calendar month per grouping" do
    queries = count_ch_queries do
      ActiveUsersReport.new(
        project_ids: [@pid], start_date: Date.new(2026, 5, 1), end_date: Date.new(2026, 7, 31)
      ).call
    end

    # 3 months x (daily + monthly): a whole-range read would OOM on a large tenant.
    assert_equal 6, queries
  end

  test "partial months at both ends stay within their own window" do
    insert_ch_events([ch_event(visitors(:android_visitor).id, "2026-06-03")])

    csv = ActiveUsersReport.new(
      project_ids: [@pid], start_date: Date.new(2026, 5, 2), end_date: Date.new(2026, 6, 10)
    ).call

    assert_includes csv, "2026-05,1"
    assert_includes csv, "2026-06,1"
  end

  private

  def report_csv
    ActiveUsersReport.new(
      project_ids: [@pid], start_date: Date.new(2026, 5, 1), end_date: Date.new(2026, 5, 2)
    ).call
  end

  def ch_event(visitor_id, date)
    {
      project_id: @pid, event_type: "view", device_id: 1, visitor_id: visitor_id,
      link_id: 0, inviter_id: 0, campaign_id: 0, platform: "ios",
      engagement_time: 0, country: "",
      created_at: Time.utc(*date.split("-").map(&:to_i), 12, 0, 0).strftime("%Y-%m-%d %H:%M:%S.000")
    }
  end
end
