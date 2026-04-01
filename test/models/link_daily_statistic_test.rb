require "test_helper"

class LinkDailyStatisticTest < ActiveSupport::TestCase
  fixtures :link_daily_statistics, :links, :domains, :redirect_configs, :projects, :instances

  # === within_range scope ===

  test "within_range returns stats within date range" do
    stats = LinkDailyStatistic.within_range(Date.parse("2026-03-01"), Date.parse("2026-03-01"))
    assert stats.any?
    stats.each do |stat|
      assert_equal Date.parse("2026-03-01"), stat.event_date
    end
  end

  test "within_range returns stats spanning multiple days" do
    stats = LinkDailyStatistic.within_range(Date.parse("2026-03-01"), Date.parse("2026-03-02"))
    dates = stats.map(&:event_date).uniq.sort
    assert_includes dates, Date.parse("2026-03-01")
    assert_includes dates, Date.parse("2026-03-02")
  end

  test "within_range returns empty for range with no data" do
    stats = LinkDailyStatistic.within_range(Date.parse("2025-01-01"), Date.parse("2025-01-02"))
    assert_empty stats
  end

  # === self.aggregate_by_link ===

  test "aggregate_by_link groups and sums metrics by link" do
    results = LinkDailyStatistic.aggregate_by_link(
      start_date: Date.parse("2026-03-01"),
      end_date: Date.parse("2026-03-02")
    )
    basic_link = links(:basic_link)
    agg = results.find { |r| r.link_id == basic_link.id }
    assert_not_nil agg
    # stat_day1 + stat_day2: views 100 + 200 = 300
    assert_equal 300, agg.views.to_i
    # opens 50 + 80 = 130
    assert_equal 130, agg.opens.to_i
    # installs 10 + 20 = 30
    assert_equal 30, agg.installs.to_i
  end

  test "aggregate_by_link sorts by specified column descending" do
    results = LinkDailyStatistic.aggregate_by_link(
      start_date: Date.parse("2026-03-01"),
      end_date: Date.parse("2026-03-02"),
      sort_by: :views
    )
    views = results.map { |r| r.views.to_i }
    assert_equal views, views.sort.reverse
  end

  test "aggregate_by_link raises for invalid sort key" do
    assert_raises(ArgumentError) do
      LinkDailyStatistic.aggregate_by_link(
        start_date: Date.parse("2026-03-01"),
        end_date: Date.parse("2026-03-02"),
        sort_by: :invalid_column
      )
    end
  end

  test "aggregate_by_link with single day range" do
    results = LinkDailyStatistic.aggregate_by_link(
      start_date: Date.parse("2026-03-01"),
      end_date: Date.parse("2026-03-01")
    )
    # Should have both basic_link and second_link stats
    link_ids = results.map(&:link_id)
    assert_includes link_ids, links(:basic_link).id
    assert_includes link_ids, links(:second_link).id
  end

  # === default attribute values ===

  test "new record has zero defaults for metric columns" do
    stat = LinkDailyStatistic.new
    assert_equal 0, stat.views
    assert_equal 0, stat.opens
    assert_equal 0, stat.installs
    assert_equal 0, stat.reinstalls
    assert_equal 0, stat.time_spent
    assert_equal 0, stat.reactivations
    assert_equal 0, stat.app_opens
    assert_equal 0, stat.user_referred
    assert_equal 0, stat.revenue
  end

  # === METRIC_COLUMNS ===

  test "METRIC_COLUMNS contains expected columns" do
    expected = %i[views opens installs reinstalls time_spent revenue reactivations app_opens user_referred]
    assert_equal expected, LinkDailyStatistic::METRIC_COLUMNS
  end
end
