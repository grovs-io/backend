require "test_helper"

class BulkUpsertHelperTest < ActiveSupport::TestCase
  fixtures :instances, :projects, :links, :domains, :redirect_configs, :link_daily_statistics,
           :visitors, :devices, :visitor_daily_statistics

  setup do
    @project = projects(:one)
    @link = links(:basic_link)
    @visitor = visitors(:ios_visitor)
  end

  # === Core behavior: insert new rows ===

  test "inserts new rows when no conflict exists" do
    new_date = Date.new(2026, 6, 1)
    rows = [{
      project_id: @project.id, link_id: @link.id, event_date: new_date,
      views: 10, opens: 5, installs: 0, reinstalls: 0, time_spent: 0,
      revenue: 0, reactivations: 0, app_opens: 0, user_referred: 0,
      created_at: Time.current, updated_at: Time.current, platform: "ios"
    }]

    assert_difference "LinkDailyStatistic.count", 1 do
      BulkUpsertHelper.execute(
        table: "link_daily_statistics",
        rows: rows,
        columns: LinkDailyStatService::COLUMNS,
        conflict_keys: LinkDailyStatService::CONFLICT_KEYS,
        metric_columns: LinkDailyStatistic::METRIC_COLUMNS
      )
    end

    row = LinkDailyStatistic.find_by(project_id: @project.id, link_id: @link.id, event_date: new_date, platform: "ios")
    assert_equal 10, row.views
    assert_equal 5, row.opens
  end

  # === Core behavior: increment on conflict ===

  test "increments metric columns on conflict" do
    # stat_day1 fixture: views=100, date=2026-03-01, platform=ios
    event_date = Date.new(2026, 3, 1)
    before = LinkDailyStatistic.find_by(project_id: @project.id, link_id: @link.id, event_date: event_date, platform: "ios")
    original_views = before.views

    rows = [{
      project_id: @project.id, link_id: @link.id, event_date: event_date,
      views: 7, opens: 0, installs: 0, reinstalls: 0, time_spent: 0,
      revenue: 0, reactivations: 0, app_opens: 0, user_referred: 0,
      created_at: Time.current, updated_at: Time.current, platform: "ios"
    }]

    assert_no_difference "LinkDailyStatistic.count" do
      BulkUpsertHelper.execute(
        table: "link_daily_statistics",
        rows: rows,
        columns: LinkDailyStatService::COLUMNS,
        conflict_keys: LinkDailyStatService::CONFLICT_KEYS,
        metric_columns: LinkDailyStatistic::METRIC_COLUMNS
      )
    end

    updated = LinkDailyStatistic.find_by(project_id: @project.id, link_id: @link.id, event_date: event_date, platform: "ios")
    assert_equal original_views + 7, updated.views
  end

  # === Empty input ===

  test "no-ops on empty rows" do
    assert_no_difference "LinkDailyStatistic.count" do
      BulkUpsertHelper.execute(
        table: "link_daily_statistics",
        rows: [],
        columns: LinkDailyStatService::COLUMNS,
        conflict_keys: LinkDailyStatService::CONFLICT_KEYS,
        metric_columns: LinkDailyStatistic::METRIC_COLUMNS
      )
    end
  end

  # === Extra conflict sets ===

  test "applies extra_conflict_sets (visitor invited_by_id COALESCE)" do
    android_visitor = visitors(:android_visitor)
    new_date = Date.new(2026, 6, 2)

    # First insert with invited_by_id
    rows = [{
      project_id: @project.id, visitor_id: @visitor.id, event_date: new_date,
      invited_by_id: android_visitor.id,
      views: 3, opens: 0, installs: 0, reinstalls: 0, time_spent: 0,
      revenue: 0, reactivations: 0, app_opens: 0, user_referred: 0,
      created_at: Time.current, updated_at: Time.current, platform: "ios"
    }]

    BulkUpsertHelper.execute(
      table: "visitor_daily_statistics",
      rows: rows,
      columns: VisitorDailyStatService::COLUMNS,
      conflict_keys: VisitorDailyStatService::CONFLICT_KEYS,
      metric_columns: VisitorDailyStatistic::METRIC_COLUMNS,
      extra_conflict_sets: ["invited_by_id = COALESCE(visitor_daily_statistics.invited_by_id, EXCLUDED.invited_by_id)"]
    )

    row = VisitorDailyStatistic.find_by(project_id: @project.id, visitor_id: @visitor.id, event_date: new_date, platform: "ios")
    assert_equal android_visitor.id, row.invited_by_id
    assert_equal 3, row.views

    # Second upsert with nil invited_by_id — should preserve the existing one
    rows2 = [{
      project_id: @project.id, visitor_id: @visitor.id, event_date: new_date,
      invited_by_id: nil,
      views: 2, opens: 0, installs: 0, reinstalls: 0, time_spent: 0,
      revenue: 0, reactivations: 0, app_opens: 0, user_referred: 0,
      created_at: Time.current, updated_at: Time.current, platform: "ios"
    }]

    BulkUpsertHelper.execute(
      table: "visitor_daily_statistics",
      rows: rows2,
      columns: VisitorDailyStatService::COLUMNS,
      conflict_keys: VisitorDailyStatService::CONFLICT_KEYS,
      metric_columns: VisitorDailyStatistic::METRIC_COLUMNS,
      extra_conflict_sets: ["invited_by_id = COALESCE(visitor_daily_statistics.invited_by_id, EXCLUDED.invited_by_id)"]
    )

    row.reload
    assert_equal android_visitor.id, row.invited_by_id, "COALESCE should preserve existing invited_by_id"
    assert_equal 5, row.views, "Views should be incremented"
  end

  # === Multiple rows in single call ===

  test "handles multiple rows in a single call" do
    date1 = Date.new(2026, 6, 3)
    date2 = Date.new(2026, 6, 4)

    rows = [
      { project_id: @project.id, link_id: @link.id, event_date: date1,
        views: 1, opens: 2, installs: 0, reinstalls: 0, time_spent: 0,
        revenue: 0, reactivations: 0, app_opens: 0, user_referred: 0,
        created_at: Time.current, updated_at: Time.current, platform: "ios" },
      { project_id: @project.id, link_id: @link.id, event_date: date2,
        views: 3, opens: 4, installs: 0, reinstalls: 0, time_spent: 0,
        revenue: 0, reactivations: 0, app_opens: 0, user_referred: 0,
        created_at: Time.current, updated_at: Time.current, platform: "ios" }
    ]

    assert_difference "LinkDailyStatistic.count", 2 do
      BulkUpsertHelper.execute(
        table: "link_daily_statistics",
        rows: rows,
        columns: LinkDailyStatService::COLUMNS,
        conflict_keys: LinkDailyStatService::CONFLICT_KEYS,
        metric_columns: LinkDailyStatistic::METRIC_COLUMNS
      )
    end

    row1 = LinkDailyStatistic.find_by(project_id: @project.id, link_id: @link.id, event_date: date1, platform: "ios")
    row2 = LinkDailyStatistic.find_by(project_id: @project.id, link_id: @link.id, event_date: date2, platform: "ios")
    assert_equal 1, row1.views
    assert_equal 3, row2.views
  end

  # === Works for both tables with same interface ===

  test "works for visitor_daily_statistics table" do
    new_date = Date.new(2026, 6, 5)

    rows = [{
      project_id: @project.id, visitor_id: @visitor.id, event_date: new_date,
      invited_by_id: nil,
      views: 8, opens: 0, installs: 0, reinstalls: 0, time_spent: 0,
      revenue: 0, reactivations: 0, app_opens: 0, user_referred: 0,
      created_at: Time.current, updated_at: Time.current, platform: "android"
    }]

    assert_difference "VisitorDailyStatistic.count", 1 do
      BulkUpsertHelper.execute(
        table: "visitor_daily_statistics",
        rows: rows,
        columns: VisitorDailyStatService::COLUMNS,
        conflict_keys: VisitorDailyStatService::CONFLICT_KEYS,
        metric_columns: VisitorDailyStatistic::METRIC_COLUMNS,
        extra_conflict_sets: ["invited_by_id = COALESCE(visitor_daily_statistics.invited_by_id, EXCLUDED.invited_by_id)"]
      )
    end

    row = VisitorDailyStatistic.find_by(project_id: @project.id, visitor_id: @visitor.id, event_date: new_date, platform: "android")
    assert_equal 8, row.views
  end

  # === Metric values are cast to integer ===

  test "metric values are cast to integer" do
    new_date = Date.new(2026, 6, 6)
    rows = [{
      project_id: @project.id, link_id: @link.id, event_date: new_date,
      views: "15", opens: 0, installs: 0, reinstalls: 0, time_spent: 0,
      revenue: 0, reactivations: 0, app_opens: 0, user_referred: 0,
      created_at: Time.current, updated_at: Time.current, platform: "ios"
    }]

    BulkUpsertHelper.execute(
      table: "link_daily_statistics",
      rows: rows,
      columns: LinkDailyStatService::COLUMNS,
      conflict_keys: LinkDailyStatService::CONFLICT_KEYS,
      metric_columns: LinkDailyStatistic::METRIC_COLUMNS
    )

    row = LinkDailyStatistic.find_by(project_id: @project.id, link_id: @link.id, event_date: new_date, platform: "ios")
    assert_equal 15, row.views
  end

  test "nil metric values are treated as 0" do
    new_date = Date.new(2026, 6, 7)
    rows = [{
      project_id: @project.id, link_id: @link.id, event_date: new_date,
      views: nil, opens: 0, installs: 0, reinstalls: 0, time_spent: 0,
      revenue: 0, reactivations: 0, app_opens: 0, user_referred: 0,
      created_at: Time.current, updated_at: Time.current, platform: "ios"
    }]

    BulkUpsertHelper.execute(
      table: "link_daily_statistics",
      rows: rows,
      columns: LinkDailyStatService::COLUMNS,
      conflict_keys: LinkDailyStatService::CONFLICT_KEYS,
      metric_columns: LinkDailyStatistic::METRIC_COLUMNS
    )

    row = LinkDailyStatistic.find_by(project_id: @project.id, link_id: @link.id, event_date: new_date, platform: "ios")
    assert_equal 0, row.views
  end

  # === Safety: extra_conflict_sets validation ===

  test "rejects unsafe extra_conflict_sets clauses" do
    rows = [{
      project_id: @project.id, link_id: @link.id, event_date: Date.new(2026, 6, 8),
      views: 1, opens: 0, installs: 0, reinstalls: 0, time_spent: 0,
      revenue: 0, reactivations: 0, app_opens: 0, user_referred: 0,
      created_at: Time.current, updated_at: Time.current, platform: "ios"
    }]

    assert_raises(ArgumentError) do
      BulkUpsertHelper.execute(
        table: "link_daily_statistics",
        rows: rows,
        columns: LinkDailyStatService::COLUMNS,
        conflict_keys: LinkDailyStatService::CONFLICT_KEYS,
        metric_columns: LinkDailyStatistic::METRIC_COLUMNS,
        extra_conflict_sets: ["views = 0; DROP TABLE users --"]
      )
    end
  end
end
