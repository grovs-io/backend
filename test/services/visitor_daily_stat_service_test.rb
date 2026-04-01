require "test_helper"

class VisitorDailyStatServiceTest < ActiveSupport::TestCase
  fixtures :instances, :projects, :visitors, :devices, :visitor_daily_statistics

  setup do
    @project = projects(:one)
    @visitor = visitors(:ios_visitor)
    @android_visitor = visitors(:android_visitor)
  end

  test "increment creates new row" do
    new_date = Date.new(2026, 4, 1)

    assert_difference "VisitorDailyStatistic.count", 1 do
      VisitorDailyStatService.increment_visitor_event(
        visitor: @visitor, event_type: :views, platform: Grovs::Platforms::IOS,
        event_date: new_date, project_id: @project.id
      )
    end

    stat = VisitorDailyStatistic.find_by(visitor_id: @visitor.id, event_date: new_date, platform: Grovs::Platforms::IOS)
    assert_equal 1, stat.views
    assert_equal 0, stat.opens
  end

  test "increment adds to existing row" do
    existing = visitor_daily_statistics(:ios_stat_day1) # views: 50
    original_views = existing.views

    VisitorDailyStatService.increment_visitor_event(
      visitor: @visitor, event_type: :views, platform: "ios",
      event_date: existing.event_date, project_id: @project.id
    )

    existing.reload
    assert_equal original_views + 1, existing.views
  end

  test "increment rejects invalid event type" do
    assert_raises(ArgumentError) do
      VisitorDailyStatService.increment_visitor_event(
        visitor: @visitor, event_type: :bogus, platform: Grovs::Platforms::IOS,
        project_id: @project.id
      )
    end
  end

  test "increment preserves existing invited_by_id" do
    # Set invited_by on the existing stat
    existing = visitor_daily_statistics(:ios_stat_day1)
    existing.update_column(:invited_by_id, @android_visitor.id)

    # Increment with a visitor that has a different inviter
    @visitor.update_column(:inviter_id, 99999)
    VisitorDailyStatService.increment_visitor_event(
      visitor: @visitor, event_type: :opens, platform: "ios",
      event_date: existing.event_date, project_id: @project.id
    )

    existing.reload
    # COALESCE keeps the original non-nil value
    assert_equal @android_visitor.id, existing.invited_by_id
  end

  test "bulk_upsert creates new rows" do
    new_date = Date.new(2026, 5, 1)

    stats = [{
      project_id: @project.id, visitor_id: @visitor.id,
      event_date: new_date, platform: Grovs::Platforms::IOS, invited_by_id: nil,
      metrics: { views: 10, opens: 5 }
    }]

    assert_difference "VisitorDailyStatistic.count", 1 do
      VisitorDailyStatService.bulk_upsert_visitor_stats(stats)
    end

    row = VisitorDailyStatistic.find_by(project_id: @project.id, visitor_id: @visitor.id, event_date: new_date, platform: Grovs::Platforms::IOS)
    assert_equal 10, row.views
    assert_equal 5, row.opens
  end

  test "bulk_upsert increments existing rows" do
    existing = visitor_daily_statistics(:ios_stat_day1)
    original_views = existing.views

    stats = [{
      project_id: @project.id, visitor_id: @visitor.id,
      event_date: existing.event_date, platform: existing.platform,
      invited_by_id: nil, metrics: { views: 3 }
    }]

    assert_no_difference "VisitorDailyStatistic.count" do
      VisitorDailyStatService.bulk_upsert_visitor_stats(stats)
    end

    existing.reload
    assert_equal original_views + 3, existing.views
  end

  test "bulk_upsert merges same key with different invited_by" do
    new_date = Date.new(2026, 5, 2)

    stats = [
      { project_id: @project.id, visitor_id: @visitor.id,
        event_date: new_date, platform: Grovs::Platforms::IOS,
        invited_by_id: nil, metrics: { views: 2 } },
      { project_id: @project.id, visitor_id: @visitor.id,
        event_date: new_date, platform: Grovs::Platforms::IOS,
        invited_by_id: @android_visitor.id, metrics: { views: 3 } }
    ]

    assert_difference "VisitorDailyStatistic.count", 1 do
      VisitorDailyStatService.bulk_upsert_visitor_stats(stats)
    end

    row = VisitorDailyStatistic.find_by(project_id: @project.id, visitor_id: @visitor.id, event_date: new_date, platform: Grovs::Platforms::IOS)
    assert_equal 5, row.views
    # First non-nil invited_by wins — second entry has the non-nil one but first was nil, so second wins
    assert_equal @android_visitor.id, row.invited_by_id
  end

  test "bulk_upsert with empty input is noop" do
    assert_no_difference "VisitorDailyStatistic.count" do
      VisitorDailyStatService.bulk_upsert_visitor_stats([])
      VisitorDailyStatService.bulk_upsert_visitor_stats(nil)
    end
  end
end
