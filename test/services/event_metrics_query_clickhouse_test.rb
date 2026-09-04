# frozen_string_literal: true

require "test_helper"

# CH paths for EventMetricsQuery: overview_ch plus the two link surfaces.
class EventMetricsQueryClickhouseTest < ActiveSupport::TestCase
  include ClickhouseTestHelper

  fixtures :projects, :instances, :domains, :links, :devices, :redirect_configs

  DAY1 = "2026-05-01"
  DAY2 = "2026-05-02"

  setup do
    skip_unless_clickhouse!
    truncate_clickhouse_tables
    @project = projects(:one)
    @pid = @project.id
    @query = EventMetricsQuery.new(project: @project)
    @link = links(:basic_link)
    @other_link = links(:second_link)
    Event.where(project: @project).delete_all

    @original_rollups = Rails.application.config.clickhouse_analytics_rollups_read_enabled
    @original_read = Rails.application.config.clickhouse_read_enabled
  end

  teardown do
    Rails.application.config.clickhouse_analytics_rollups_read_enabled = @original_rollups
    Rails.application.config.clickhouse_read_enabled = @original_read
  end

  test "aggregates daily event-type counts from CH events" do
    seed([
      ev(DAY1, "view"), ev(DAY1, "view"), ev(DAY1, "install"),
      ev(DAY1, "open"), ev(DAY2, "view"), ev(DAY2, "app_open")
    ])

    data = @query.overview_ch([@pid], DAY1, DAY2)

    assert_equal 2, data["#{DAY1} 00:00:00 UTC"][:view]
    assert_equal 1, data["#{DAY1} 00:00:00 UTC"][:install]
    assert_equal 1, data["#{DAY1} 00:00:00 UTC"][:open]
    assert_equal 1, data["#{DAY2} 00:00:00 UTC"][:view]
    assert_equal 1, data["#{DAY2} 00:00:00 UTC"][:app_open]
  end

  test "campaign_ids filter scopes to matching campaigns; [] matches nothing" do
    seed([
      ev(DAY1, "view", campaign_id: 7), ev(DAY1, "view", campaign_id: 7),
      ev(DAY1, "view", campaign_id: 9)
    ])

    scoped = @query.overview_ch([@pid], DAY1, DAY2, campaign_ids: [7])
    assert_equal 2, scoped["#{DAY1} 00:00:00 UTC"][:view]

    assert_empty @query.overview_ch([@pid], DAY1, DAY2, campaign_ids: [])
  end

  test "sdk_generated filter excludes SDK events" do
    seed([
      ev(DAY1, "view", sdk_generated: 0), ev(DAY1, "view", sdk_generated: 0),
      ev(DAY1, "view", sdk_generated: 1)
    ])

    data = @query.overview_ch([@pid], DAY1, DAY2, sdk_generated: false)
    assert_equal 2, data["#{DAY1} 00:00:00 UTC"][:view]
  end

  test "excludes other projects and out-of-range days" do
    seed([
      ev(DAY1, "view"),
      ev("2026-04-01", "view"),
      { project_id: 999_999, event_type: "view", created_at: ts(DAY1), campaign_id: 0,
        sdk_generated: 0, engagement_time: 0, platform: "ios" }
    ])

    data = @query.overview_ch([@pid], DAY1, DAY2)
    assert_equal 1, data["#{DAY1} 00:00:00 UTC"][:view]
    assert_not data.key?("2026-04-01 00:00:00 UTC")
  end

  test "metrics_for_link_ids reads the breakdown rollup, not raw events" do
    enable_rollup_reads
    pg_event(@link, "view") # PG says 1 view; CH says 9
    seed_link_daily(@link.id, view: 9, install: 2, reactivation: 1)

    metrics = @query.metrics_for_link_ids([@link.id], Date.parse(DAY1), Date.parse(DAY2))[@link.id]

    assert_equal 9, metrics[:view]
    assert_equal 2, metrics[:install]
    assert_equal 1, metrics[:reactivation]
    assert_equal 0.0, metrics[:avg_engagement_time], "engagement average is 0.0 by decision"
  end

  test "avg_engagement_time is the average session length in seconds for the link" do
    enable_rollup_reads
    seed_link_daily(@link.id, view: 1)
    # Two sessions off this link: 30s and 90s -> 60.0 average.
    seed_link_sessions(@link.id, sessions: 2, duration_ms: 120_000)

    metrics = @query.metrics_for_link_ids([@link.id], Date.parse(DAY1), Date.parse(DAY2))[@link.id]

    assert_equal 60.0, metrics[:avg_engagement_time]
  end

  test "session averages sum before dividing, never averaging averages" do
    enable_rollup_reads
    seed_link_daily(@link.id, view: 1)
    # 1 session of 10s on DAY1, 3 sessions totalling 30s on DAY2 -> 40s/4 = 10.0, not 7.5.
    seed_link_sessions(@link.id, sessions: 1, duration_ms: 10_000, date: DAY1)
    seed_link_sessions(@link.id, sessions: 3, duration_ms: 30_000, date: DAY2)

    metrics = @query.metrics_for_link_ids([@link.id], Date.parse(DAY1), Date.parse(DAY2))[@link.id]

    assert_equal 10.0, metrics[:avg_engagement_time]
  end

  test "a link with no sessions keeps 0.0 without losing its counts" do
    enable_rollup_reads
    seed_link_daily(@link.id, view: 7)

    metrics = @query.metrics_for_link_ids([@link.id], Date.parse(DAY1), Date.parse(DAY2))[@link.id]

    assert_equal 7, metrics[:view]
    assert_equal 0.0, metrics[:avg_engagement_time]
  end

  test "a failed session read leaves the counts intact" do
    enable_rollup_reads
    seed_link_daily(@link.id, view: 7)

    metrics = ClickhouseReadService.stub(:link_session_avg_seconds, nil) do
      @query.metrics_for_link_ids([@link.id], Date.parse(DAY1), Date.parse(DAY2))
    end

    assert_equal 7, metrics[@link.id][:view]
    assert_equal 0.0, metrics[@link.id][:avg_engagement_time]
  end

  test "sorted_by_links carries the session average too" do
    enable_rollup_reads
    seed_sortable(@link.id, views: 2)
    seed_link_sessions(@link.id, sessions: 1, duration_ms: 45_000)

    rows = sorted(asc: false)[:result]

    assert_equal 45.0, rows.first[:metrics][:avg_engagement_time]
  end

  test "metrics_for_link_ids keeps custom and screen_view, which have no counter column" do
    enable_rollup_reads
    seed_link_daily(@link.id, view: 1, custom: 3, screen_view: 2)

    metrics = @query.metrics_for_link_ids([@link.id], Date.parse(DAY1), Date.parse(DAY2))[@link.id]

    assert_equal 3, metrics[:custom]
    assert_equal 2, metrics[:screen_view]
  end

  test "metrics_for_link_ids counts time_spent EVENTS, as the raw-events scan did" do
    enable_rollup_reads
    seed_link_daily(@link.id, time_spent: 4)

    metrics = @query.metrics_for_link_ids([@link.id], Date.parse(DAY1), Date.parse(DAY2))[@link.id]

    assert_equal 4, metrics[:time_spent]
  end

  test "metrics_for_link_ids omits links with no rollup rows in range" do
    enable_rollup_reads
    seed_link_daily(@link.id, view: 3)

    metrics = @query.metrics_for_link_ids([@link.id, @other_link.id], Date.parse(DAY1), Date.parse(DAY2))

    assert_equal [@link.id], metrics.keys
  end

  test "metrics_for_link_ids falls back to PG when CH is unavailable" do
    enable_rollup_reads
    pg_event(@link, "view")

    metrics = ClickhouseReadService.stub(:link_event_type_counts, nil) do
      @query.metrics_for_link_ids([@link.id], Date.parse(DAY1), Date.parse(DAY2))
    end

    assert_equal 1, metrics[@link.id][:view], "PG fallback, not zeros"
  end

  test "flag off keeps metrics_for_link_ids on raw events" do
    pg_event(@link, "view")
    seed_link_daily(@link.id, view: 9)

    metrics = @query.metrics_for_link_ids([@link.id], Date.parse(DAY1), Date.parse(DAY2))

    assert_equal 1, metrics[@link.id][:view]
  end

  test "sorted_by_links orders by the rollup metric and carries its counts" do
    enable_rollup_reads
    seed_sortable(@link.id, views: 2)
    seed_sortable(@other_link.id, views: 7)

    result = sorted(asc: false)

    assert_equal [@other_link.id, @link.id], result[:result].map { |r| r[:link].id }
    assert_equal 7, result[:result].first[:metrics][:view]
    assert_equal 1, result[:total_pages]
  end

  test "sorted_by_links ascending puts the smallest active link first" do
    enable_rollup_reads
    seed_sortable(@link.id, views: 2)
    seed_sortable(@other_link.id, views: 7)

    ids = sorted(asc: true)[:result].map { |r| r[:link].id }

    assert_equal [@link.id, @other_link.id], ids
  end

  test "links with no rollup rows sort last with nil metrics in both directions" do
    enable_rollup_reads
    seed_sortable(@link.id, views: 2)

    [true, false].each do |asc|
      rows = sorted(asc: asc)[:result]

      assert_equal [@link.id, @other_link.id], rows.map { |r| r[:link].id }, "asc=#{asc}"
      assert_nil rows.last[:metrics], "no-activity links keep the legacy nil metrics"
    end
  end

  # A link holding OTHER event types has a real rollup row but a 0 count for the sorted
  # type; it must join the zero tail, not sort ahead of links that actually have the type.
  test "zero-of-this-type links tail regardless of whether they have other event types" do
    enable_rollup_reads
    third = Link.create!(domain: @link.domain, path: "third-#{SecureRandom.hex(4)}",
                         redirect_config: @link.redirect_config,
                         generated_from_platform: "ios")
    seed_link_daily(@link.id, install: 5)   # rows, but zero views
    seed_link_daily(@other_link.id, view: 3)
    # `third` has no rows at all

    ascending = sorted(asc: true, links: [@link.id, @other_link.id, third.id])[:result]

    assert_equal @other_link.id, ascending.first[:link].id,
                 "the only link with views must lead an ASC sort, not a zero"
    assert_equal [@link.id, third.id].sort, ascending.drop(1).map { |r| r[:link].id }.sort
    assert_equal 3, ascending.first[:metrics][:view]
  end

  test "sorted_by_links without a page returns a bare array of every link" do
    enable_rollup_reads
    seed_sortable(@link.id, views: 2)

    result = sorted(asc: false, page: nil)

    assert_kind_of Array, result
    assert_equal [@link.id, @other_link.id], result.map { |r| r[:link].id }
  end

  # "custom" IS served from link_daily now, so the uncovered case is a type that is not an
  # event type at all. Asserts the PG-sourced value, not just membership.
  test "an event type outside Grovs::Events::ALL falls back to PG" do
    enable_rollup_reads
    pg_event(@link, "view")
    seed_link_daily(@link.id, view: 9) # CH would say 9; PG says 1

    result = sorted(asc: false, event_type: "created_at")

    assert_equal 1, result[:result].find { |r| r[:link].id == @link.id }[:metrics][:view],
                 "PG path must serve PG counts"
  end

  test "time_spent sorts by event COUNT, matching the value it displays" do
    enable_rollup_reads
    # @link: one 100-second event. @other_link: two 1-second events.
    seed_link_daily(@link.id, engagement: 100, time_spent: 1)
    seed_link_daily(@other_link.id, engagement: 2, time_spent: 2)

    rows = sorted(asc: false, event_type: "time_spent")[:result]

    assert_equal [@other_link.id, @link.id], rows.map { |r| r[:link].id },
                 "2 events must outrank 1, even though its engagement is lower"
    assert_equal 2, rows.first[:metrics][:time_spent]
    assert_equal 1, rows.last[:metrics][:time_spent]
  end

  test "custom is sortable now that rank and value share a table" do
    enable_rollup_reads
    seed_link_daily(@link.id, custom: 1)
    seed_link_daily(@other_link.id, custom: 5)

    rows = sorted(asc: false, event_type: Grovs::Events::CUSTOM)[:result]

    assert_equal [@other_link.id, @link.id], rows.map { |r| r[:link].id }
    assert_equal 5, rows.first[:metrics][:custom]
  end

  test "sorted_by_links falls back to PG when the rollup page read fails" do
    enable_rollup_reads
    pg_event(@link, "view")

    result = ClickhouseReadService.stub(:link_event_sorted_page, nil) { sorted(asc: false) }

    assert_equal 1, result[:result].first[:metrics][:view]
  end

  test "a candidate set beyond the cap falls back to PG" do
    enable_rollup_reads
    pg_event(@link, "view")

    result = @query.stub(:metric_sort_id_cap, 1) { sorted(asc: false) }

    assert_equal 1, result[:result].first[:metrics][:view]
  end

  private

  def enable_rollup_reads
    Rails.application.config.clickhouse_read_enabled = true
    Rails.application.config.clickhouse_analytics_rollups_read_enabled = true
  end

  def sorted(asc:, page: 1, event_type: "view", links: nil)
    @query.sorted_by_links(
      links: Link.where(id: links || [@link.id, @other_link.id]), page: page,
      event_type: event_type, asc: asc,
      start_date: Date.parse(DAY1), end_date: Date.parse(DAY2)
    )
  end

  def pg_event(link, event, day: DAY1)
    Event.create!(project: @project, device: devices(:ios_device), link: link, event: event,
                  platform: "ios", engagement_time: 0, created_at: "#{day} 10:00:00")
  end

  def seed_sortable(link_id, views:)
    seed_link_daily(link_id, view: views)
  end

  def seed_link_sessions(link_id, sessions:, duration_ms:, date: DAY1)
    Clickhouse.with do |conn|
      conn.insert("link_session_daily", [{
        project_id: @pid, link_id: link_id, event_date: date, platform: "ios",
        sessions: sessions, duration_ms_sum: duration_ms,
        engaged_sessions: sessions, engaged_duration_ms_sum: duration_ms
      }])
    end
  end

  def seed_link_daily(link_id, engagement: 0, **counts)
    rows = counts.map do |event_type, cnt|
      { project_id: @pid, link_id: link_id, campaign_id: 0, event_date: DAY1,
        event_type: event_type.to_s, platform: "ios", cnt: cnt,
        total_engagement_time: engagement }
    end
    Clickhouse.with { |conn| conn.insert("link_daily", rows) }
  end

  def seed(rows)
    insert_ch_events(rows)
  end

  def ts(day)
    "#{day} 12:00:00.000"
  end

  def ev(day, type, campaign_id: 0, sdk_generated: 0)
    {
      project_id: @pid, event_type: type, created_at: ts(day),
      campaign_id: campaign_id, sdk_generated: sdk_generated,
      engagement_time: 0, platform: "ios"
    }
  end
end
