require "test_helper"

class LinkDailyStatServiceTest < ActiveSupport::TestCase
  fixtures :instances, :projects, :links, :domains, :redirect_configs, :link_daily_statistics

  setup do
    @project = projects(:one)
    @link = links(:basic_link)
  end

  test "increment creates new row when none exists" do
    new_date = Date.new(2026, 4, 1)

    assert_difference "LinkDailyStatistic.count", 1 do
      LinkDailyStatService.increment_link_event(
        event_type: :views, project_id: @project.id,
        link_id: @link.id, platform: Grovs::Platforms::IOS, event_date: new_date
      )
    end

    stat = LinkDailyStatistic.find_by(project_id: @project.id, link_id: @link.id, event_date: new_date, platform: Grovs::Platforms::IOS)
    assert_equal 1, stat.views
    assert_equal 0, stat.opens
    assert_equal 0, stat.installs
  end

  test "increment adds to existing row" do
    # stat_day1 fixture: views=100, link=basic_link, date=2026-03-01, platform=ios
    event_date = Date.new(2026, 3, 1)
    before = LinkDailyStatistic.find_by(project_id: @project.id, link_id: @link.id, event_date: event_date, platform: "ios")
    original_views = before.views

    LinkDailyStatService.increment_link_event(
      event_type: :views, project_id: @project.id,
      link_id: @link.id, platform: "ios", event_date: event_date
    )

    updated = LinkDailyStatistic.find_by(project_id: @project.id, link_id: @link.id, event_date: event_date, platform: "ios")
    assert_equal original_views + 1, updated.views
  end

  test "increment rejects invalid event type" do
    assert_raises(ArgumentError) do
      LinkDailyStatService.increment_link_event(
        event_type: :bogus, project_id: @project.id,
        link_id: @link.id, platform: Grovs::Platforms::IOS
      )
    end
  end

  test "increment time_spent accumulates value" do
    new_date = Date.new(2026, 4, 2)

    LinkDailyStatService.increment_link_event(
      event_type: :time_spent, project_id: @project.id,
      link_id: @link.id, platform: Grovs::Platforms::IOS, event_date: new_date, value: 3500
    )

    stat = LinkDailyStatistic.find_by(project_id: @project.id, link_id: @link.id, event_date: new_date, platform: Grovs::Platforms::IOS)
    assert_equal 3500, stat.time_spent
  end

  test "bulk_upsert creates rows for new combos" do
    new_date = Date.new(2026, 5, 1)

    stats = [{
      project_id: @project.id, link_id: @link.id, event_date: new_date, platform: Grovs::Platforms::IOS,
      metrics: { views: 10, opens: 5, installs: 2 }
    }]

    assert_difference "LinkDailyStatistic.count", 1 do
      LinkDailyStatService.bulk_upsert_link_stats(stats)
    end

    row = LinkDailyStatistic.find_by(project_id: @project.id, link_id: @link.id, event_date: new_date, platform: Grovs::Platforms::IOS)
    assert_equal 10, row.views
    assert_equal 5, row.opens
    assert_equal 2, row.installs
  end

  test "bulk_upsert increments existing rows" do
    # stat_day1 fixture: views=100, link=basic_link, date=2026-03-01, platform=ios
    event_date = Date.new(2026, 3, 1)
    before = LinkDailyStatistic.find_by(project_id: @project.id, link_id: @link.id, event_date: event_date, platform: "ios")
    original_views = before.views

    stats = [{
      project_id: @project.id, link_id: @link.id,
      event_date: event_date, platform: "ios",
      metrics: { views: 7 }
    }]

    assert_no_difference "LinkDailyStatistic.count" do
      LinkDailyStatService.bulk_upsert_link_stats(stats)
    end

    updated = LinkDailyStatistic.find_by(project_id: @project.id, link_id: @link.id, event_date: event_date, platform: "ios")
    assert_equal original_views + 7, updated.views
  end

  test "bulk_upsert groups duplicate keys" do
    new_date = Date.new(2026, 5, 2)

    stats = [
      { project_id: @project.id, link_id: @link.id, event_date: new_date, platform: Grovs::Platforms::IOS,
        metrics: { views: 3 } },
      { project_id: @project.id, link_id: @link.id, event_date: new_date, platform: Grovs::Platforms::IOS,
        metrics: { views: 4 } }
    ]

    assert_difference "LinkDailyStatistic.count", 1 do
      LinkDailyStatService.bulk_upsert_link_stats(stats)
    end

    row = LinkDailyStatistic.find_by(project_id: @project.id, link_id: @link.id, event_date: new_date, platform: Grovs::Platforms::IOS)
    assert_equal 7, row.views
  end

  test "bulk_upsert with empty input is noop" do
    assert_no_difference "LinkDailyStatistic.count" do
      LinkDailyStatService.bulk_upsert_link_stats([])
      LinkDailyStatService.bulk_upsert_link_stats(nil)
    end
  end

  test "bulk_upsert sorts rows by conflict key before INSERT" do
    new_date = Date.new(2026, 5, 3)
    second_link = links(:second_link)

    # Pass in reverse order — service should sort by (project_id, link_id, date, platform)
    stats = [
      { project_id: @project.id, link_id: second_link.id, event_date: new_date, platform: Grovs::Platforms::ANDROID,
        metrics: { views: 1 } },
      { project_id: @project.id, link_id: @link.id, event_date: new_date, platform: Grovs::Platforms::IOS,
        metrics: { views: 2 } }
    ]

    # Verify the sort happens by inspecting the SQL VALUES clause order
    executed_sql = nil
    callback = lambda { |_name, _start, _finish, _id, payload|
      sql = payload[:sql]
      executed_sql = sql if sql&.include?('INSERT INTO "link_daily_statistics"')
    }
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
      LinkDailyStatService.bulk_upsert_link_stats(stats)
    end

    assert executed_sql, "Should have executed an INSERT"
    # The smaller link_id should appear first in VALUES clause
    first_link_pos = executed_sql.index(@link.id.to_s)
    second_link_pos = executed_sql.index(second_link.id.to_s)
    if @link.id < second_link.id
      assert first_link_pos < second_link_pos, "Rows should be sorted by link_id ascending"
    else
      assert second_link_pos < first_link_pos, "Rows should be sorted by link_id ascending"
    end
  end
end
