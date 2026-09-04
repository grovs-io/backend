require "test_helper"

class VisitorDailyStatisticTest < ActiveSupport::TestCase
  fixtures :visitor_daily_statistics, :visitors, :projects, :devices, :instances

  # === within_range scope ===

  test "within_range returns stats within date range" do
    stats = VisitorDailyStatistic.within_range(Date.parse("2026-03-01"), Date.parse("2026-03-01"))
    assert stats.any?
    stats.each do |stat|
      assert_equal Date.parse("2026-03-01"), stat.event_date
    end
  end

  test "within_range returns stats spanning multiple days" do
    stats = VisitorDailyStatistic.within_range(Date.parse("2026-03-01"), Date.parse("2026-03-02"))
    dates = stats.map(&:event_date).uniq.sort
    assert_includes dates, Date.parse("2026-03-01")
    assert_includes dates, Date.parse("2026-03-02")
  end

  test "within_range returns empty for range with no data" do
    stats = VisitorDailyStatistic.within_range(Date.parse("2025-01-01"), Date.parse("2025-01-02"))
    assert_empty stats
  end

  # === self.merge_visitors! ===

  test "merge_visitors! moves stats from one visitor to another" do
    from_visitor = visitors(:android_visitor)
    to_visitor = visitors(:ios_visitor)
    from_id = from_visitor.id
    to_id = to_visitor.id

    # Record initial state
    from_count = VisitorDailyStatistic.where(visitor_id: from_id).count
    assert from_count > 0, "Source visitor must have stats for this test"

    from_day1 = visitor_daily_statistics(:android_stat_day1)
    to_day1 = visitor_daily_statistics(:ios_stat_day1)

    VisitorDailyStatistic.merge_visitors!(from_id: from_id, to_id: to_id)

    # Source visitor's stats should be deleted
    assert_equal 0, VisitorDailyStatistic.where(visitor_id: from_id).count

    # Fixtures have different platforms (ios vs android) for the same date,
    # so after a platform-aware merge they remain as separate rows.
    ios_merged = VisitorDailyStatistic.find_by(visitor_id: to_id, event_date: Date.parse("2026-03-01"), platform: "ios")
    android_merged = VisitorDailyStatistic.find_by(visitor_id: to_id, event_date: Date.parse("2026-03-01"), platform: "android")
    assert_not_nil ios_merged
    assert_not_nil android_merged
    assert_equal to_day1.views, ios_merged.views, "iOS stat should be unchanged (no conflict)"
    assert_equal from_day1.views, android_merged.views, "Android stat should be moved as-is"
  end

  test "merge_visitors! creates new record if target has no stat for that date" do
    # Create a new stat on a unique date for the source
    from_visitor = visitors(:android_visitor)
    to_visitor = visitors(:ios_visitor)
    unique_date = Date.parse("2026-03-15")

    VisitorDailyStatistic.create!(
      visitor: from_visitor,
      project_id: 1,
      event_date: unique_date,
      platform: "android",
      views: 77
    )

    VisitorDailyStatistic.merge_visitors!(from_id: from_visitor.id, to_id: to_visitor.id)

    new_stat = VisitorDailyStatistic.find_by(visitor_id: to_visitor.id, event_date: unique_date)
    assert_not_nil new_stat
    assert_equal 77, new_stat.views
  end

  test "merge_visitors! keeps the target's invited_by_id and adopts the source's when target has none" do
    from_visitor = visitors(:android_visitor)
    to_visitor = visitors(:ios_visitor)
    date = Date.parse("2027-07-01")

    VisitorDailyStatistic.create!(visitor: from_visitor, project_id: from_visitor.project_id,
                                  event_date: date, platform: "ios", views: 1, invited_by_id: 4242)
    VisitorDailyStatistic.create!(visitor: to_visitor, project_id: to_visitor.project_id,
                                  event_date: date, platform: "ios", views: 2, invited_by_id: nil)

    VisitorDailyStatistic.merge_visitors!(from_id: from_visitor.id, to_id: to_visitor.id)

    merged = VisitorDailyStatistic.find_by(visitor_id: to_visitor.id, event_date: date, platform: "ios")
    assert_equal 3, merged.views
    assert_equal 4242, merged.invited_by_id, "nil target invited_by_id should adopt the source's value"
  end

  test "merge_visitors! nulls invited_by_id that would self-attribute the target" do
    from_visitor = visitors(:android_visitor)
    to_visitor = visitors(:ios_visitor) # to_visitor invited from_visitor
    date = Date.parse("2027-08-01")
    VisitorDailyStatistic.create!(visitor: from_visitor, project_id: from_visitor.project_id,
                                  event_date: date, platform: "ios", views: 1,
                                  invited_by_id: to_visitor.id)

    VisitorDailyStatistic.merge_visitors!(from_id: from_visitor.id, to_id: to_visitor.id)

    merged = VisitorDailyStatistic.find_by(visitor_id: to_visitor.id, event_date: date, platform: "ios")
    assert_nil merged.invited_by_id, "moved rows must not credit the target as its own inviter"
  end

  test "merge_visitors! raises when from and to are the same" do
    visitor = visitors(:ios_visitor)
    assert_raises(ArgumentError) do
      VisitorDailyStatistic.merge_visitors!(from_id: visitor.id, to_id: visitor.id)
    end
  end

  test "merge_visitors! sums all metric columns when platforms match" do
    from_visitor = visitors(:android_visitor)
    to_visitor = visitors(:ios_visitor)

    # Create same-platform stats so they actually merge by summing
    date = Date.parse("2026-03-10")
    from_stat = VisitorDailyStatistic.create!(
      visitor: from_visitor, project_id: 1, event_date: date, platform: "ios",
      views: 10, opens: 5, installs: 2, reinstalls: 1, time_spent: 100,
      revenue: 50, reactivations: 1, app_opens: 3, user_referred: 1
    )
    to_stat = VisitorDailyStatistic.create!(
      visitor: to_visitor, project_id: 1, event_date: date, platform: "ios",
      views: 20, opens: 10, installs: 4, reinstalls: 2, time_spent: 200,
      revenue: 100, reactivations: 2, app_opens: 6, user_referred: 2
    )

    expected = {}
    VisitorDailyStatistic::METRIC_COLUMNS.each do |col|
      expected[col] = from_stat[col].to_i + to_stat[col].to_i
    end

    VisitorDailyStatistic.merge_visitors!(from_id: from_visitor.id, to_id: to_visitor.id)

    merged = VisitorDailyStatistic.find_by(visitor_id: to_visitor.id, event_date: date, platform: "ios")
    VisitorDailyStatistic::METRIC_COLUMNS.each do |col|
      assert_equal expected[col], merged[col].to_i, "Expected #{col} to be #{expected[col]}"
    end
  end

  test "merge_visitors! keeps different platforms as separate rows" do
    from_visitor = visitors(:android_visitor)
    to_visitor = visitors(:ios_visitor)

    date = Date.parse("2026-03-20")

    VisitorDailyStatistic.create!(
      visitor: from_visitor, project_id: 1, event_date: date,
      platform: "ios", views: 10
    )
    VisitorDailyStatistic.create!(
      visitor: from_visitor, project_id: 1, event_date: date,
      platform: "android", views: 20
    )
    VisitorDailyStatistic.create!(
      visitor: to_visitor, project_id: 1, event_date: date,
      platform: "ios", views: 5
    )

    VisitorDailyStatistic.merge_visitors!(from_id: from_visitor.id, to_id: to_visitor.id)

    assert_equal 0, VisitorDailyStatistic.where(visitor_id: from_visitor.id).count

    ios_stat = VisitorDailyStatistic.find_by(visitor_id: to_visitor.id, event_date: date, platform: "ios")
    android_stat = VisitorDailyStatistic.find_by(visitor_id: to_visitor.id, event_date: date, platform: "android")

    assert_not_nil ios_stat, "iOS row should exist"
    assert_not_nil android_stat, "Android row should exist as separate record"
    assert_equal 15, ios_stat.views, "iOS views should be summed (10 + 5)"
    assert_equal 20, android_stat.views, "Android views should be inserted as-is"
  end

  # === self.aggregate_by_visitor ===

  test "aggregate_by_visitor groups and sums metrics" do
    results = VisitorDailyStatistic.aggregate_by_visitor(
      start_date: Date.parse("2026-03-01"),
      end_date: Date.parse("2026-03-02")
    )
    ios_visitor = visitors(:ios_visitor)
    agg = results.find { |r| r.visitor_id == ios_visitor.id }
    assert_not_nil agg
    # ios_stat_day1 + ios_stat_day2: views 50 + 80 = 130
    assert_equal 130, agg.views.to_i
  end

  test "aggregate_by_visitor sorts by specified column descending" do
    results = VisitorDailyStatistic.aggregate_by_visitor(
      start_date: Date.parse("2026-03-01"),
      end_date: Date.parse("2026-03-02"),
      sort_by: :views
    )
    views = results.map { |r| r.views.to_i }
    assert_equal views, views.sort.reverse
  end

  test "aggregate_by_visitor raises for invalid sort key" do
    assert_raises(ArgumentError) do
      VisitorDailyStatistic.aggregate_by_visitor(
        start_date: Date.parse("2026-03-01"),
        end_date: Date.parse("2026-03-02"),
        sort_by: :invalid_column
      )
    end
  end

  # === METRIC_COLUMNS ===

  test "METRIC_COLUMNS contains expected columns" do
    expected = %i[views opens installs reinstalls time_spent revenue reactivations app_opens user_referred]
    assert_equal expected, VisitorDailyStatistic::METRIC_COLUMNS
  end

  # === default attribute values ===

  test "new record has zero defaults for metric columns" do
    stat = VisitorDailyStatistic.new
    assert_equal 0, stat.views
    assert_equal 0, stat.opens
    assert_equal 0, stat.installs
    assert_equal 0, stat.reinstalls
    assert_equal 0, stat.time_spent
    assert_equal 0, stat.revenue
    assert_equal 0, stat.reactivations
    assert_equal 0, stat.app_opens
    assert_equal 0, stat.user_referred
  end
end
