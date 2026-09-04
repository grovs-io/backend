# frozen_string_literal: true

require "test_helper"
require_relative "../auth_test_helper"
require_relative "scenario_dsl"
require_relative "scenario_input"

# Pass B: analytics READ services match an independent Ruby tally (never the prod
# aggregation). Datasets are non-degenerate (distinct < raw visitors, decoys) so
# a uniq->count / grouping / date-filter regression can't pass silently.
class AnalyticsMetricsTest < ActionDispatch::IntegrationTest
  include AuthTestHelper
  include ClickhouseTestHelper
  include AnalyticsMatrix::ScenarioDSL

  fixtures :instances, :projects, :devices, :visitors, :domains, :redirect_configs,
           :campaigns, :links

  setup do
    matrix_setup!
    @project = projects(:one)
    @today = Date.current            # pinned once; reused so a midnight cross can't drift
    @start_date = @today - 1
    @end_date   = @today + 1
    # The PG rollup tables ship with fixture data for project one. CH is
    # truncated per test, but these aren't — clear them (rolled back per test) so
    # the dashboard/rollup reflect ONLY what this test ingests.
    [VisitorDailyStatistic, LinkDailyStatistic, DailyProjectMetric].each do |model|
      model.where(project_id: @project.id).delete_all
    end
  end

  teardown { matrix_teardown! }

  # --- helpers --------------------------------------------------------------

  # Fresh device + visitor (optionally backdated for retention cohorts).
  def make_visitor(created_at: nil, platform: "ios")
    device = Device.create!(
      user_agent: "metrics", ip: "1.1.1.1", remote_ip: "2.2.2.2",
      platform: platform, vendor: "mx-#{SecureRandom.hex(6)}"
    )
    attrs = {
      project: @project, device: device, web_visitor: false,
      sdk_identifier: "mx-#{SecureRandom.hex(4)}", uuid: SecureRandom.uuid
    }
    attrs[:created_at] = created_at if created_at
    [device, Visitor.create!(**attrs)]
  end

  def raw_event(device:, type:, session_id:, link: nil, at: nil)
    {
      type: type, project_id: @project.id, device_id: device.id, link_id: link&.id,
      data: nil, engagement_time: nil, created_at: (at || Time.current).utc.iso8601(3),
      event_name: "", session_id: session_id, tags: []
    }.to_json
  end

  def fresh_event(type:, link: nil, at: nil)
    device, = make_visitor
    raw_event(device: device, type: type, session_id: SecureRandom.hex(8), link: link, at: at)
  end

  def volume_count(event_type)
    res = Analytics::EventsQueryService.volume(
      @project.id, start_date: @start_date, end_date: @end_date,
      filters: [{ "field" => "event_type", "operator" => "is", "value" => event_type }]
    )
    res[:buckets].sum { |b| (b["count"] || b[:count]).to_i }
  end

  def dashboard_current
    DashboardMetrics.call(
      project_id: @project.id, start_time: @start_date, end_time: @end_date
    )[:current]
  end

  # --- Pass B: raw counts (CH events) + date filtering ----------------------

  test "events volume per type matches raw counts and excludes out-of-window events" do
    ingest_via_process_batch([
      fresh_event(type: "open"), fresh_event(type: "open"), fresh_event(type: "view")
    ])
    # decoy far outside the queried range must NOT be counted
    ingest_via_process_batch([fresh_event(type: "open", at: 10.days.ago)])

    assert_equal 2, volume_count("open"), "out-of-window open must be excluded"
    assert_equal 1, volume_count("view")
    assert_equal 0, volume_count("install")
  end

  # --- Pass B: DISTINCT-visitor semantics + source classifier ---------------

  test "sources breakdown counts DISTINCT visitors and separates organic from campaign" do
    links(:campaign_link).update!(campaign: campaigns(:one))
    organic_a, = make_visitor # 3 events, still ONE distinct visitor
    organic_b, = make_visitor # 1 event
    campaign_c, = make_visitor # 1 campaign event
    ingest_via_process_batch([
      raw_event(device: organic_a, type: "open",     session_id: "a1"),
      raw_event(device: organic_a, type: "open",     session_id: "a2"),
      raw_event(device: organic_a, type: "app_open", session_id: "a3"),
      raw_event(device: organic_b, type: "open",     session_id: "b1"),
      raw_event(device: campaign_c, type: "open",    session_id: "c1", link: links(:campaign_link))
    ])

    res = Analytics::OverviewStatsService.sources_breakdown(
      @project.id, start_date: @start_date, end_date: @end_date
    )
    organic = res[:sources].find { |s| s[:name] == "Organic" }
    campaigns = res[:sources].find { |s| s[:name] == "Campaigns" }
    assert_equal 2, organic[:value], "2 DISTINCT organic visitors, not 4 raw events"
    assert_not_nil campaigns, "campaign traffic must not be misclassified as organic"
    assert_equal 1, campaigns[:value]
  end

  test "user_trends reports install-qualified new users rather than all daily visitors" do
    visitor_a, = make_visitor # views and opens only — not a new user
    visitor_b, = make_visitor # first activity includes an install — new user
    ingest_via_process_batch([
      raw_event(device: visitor_a, type: "open",     session_id: "a1"),
      raw_event(device: visitor_a, type: "open",     session_id: "a2"),
      raw_event(device: visitor_a, type: "view",     session_id: "a3"),
      raw_event(device: visitor_b, type: "install",  session_id: "b1"),
      raw_event(device: visitor_b, type: "app_open", session_id: "b2")
    ])
    res = Analytics::OverviewStatsService.user_trends(
      @project.id, start_date: @start_date, end_date: @end_date
    )
    point = res[:points].find { |p| (p[:date] || p["date"]).to_s == @today.to_s }
    assert_not_nil point, "expected a trend point for today"
    assert_equal 1, (point[:new_users] || point["new_users"]).to_i,
                 "only the first-time visitor with an install is a new user"
    assert_equal 1, (point[:users] || point["users"]).to_i,
                 "legacy dashboards receive the corrected metric during rollout"
    card_new_users = Analytics::OverviewStatsService.key_metrics(
      @project.id, start_date: @start_date, end_date: @end_date
    ).dig(:metrics, :new_users)
    assert_equal card_new_users, res[:points].sum { |p| p[:new_users] },
                 "the trend sum must match the New users card"
  end

  test "user_trends uses the same raw platform classification as the New users card" do
    ios, = make_visitor(platform: "ios")
    desktop, = make_visitor(platform: "desktop")
    ingest_via_process_batch([
      raw_event(device: ios, type: "install", session_id: "ios-install"),
      raw_event(device: desktop, type: "install", session_id: "desktop-install")
    ])

    trends = Analytics::OverviewStatsService.user_trends(
      @project.id, start_date: @start_date, end_date: @end_date, platform: "desktop"
    )
    card = Analytics::OverviewStatsService.key_metrics(
      @project.id, start_date: @start_date, end_date: @end_date, platform: "desktop"
    )

    assert_equal 1, trends[:points].sum { |p| p[:new_users] }
    assert_equal card.dig(:metrics, :new_users), trends[:points].sum { |p| p[:new_users] }
  end

  test "user_trends assigns a new user to first activity day when installation happens later" do
    instances(:one).update!(cold_storage_days: 365, delete_days: 730)
    device, = make_visitor
    first_activity_day = @today - 2
    install_day = @today
    at_noon = ->(date) { Time.zone.local(date.year, date.month, date.day, 12) }
    ingest_via_process_batch([
      raw_event(
        device: device, type: "view", session_id: "first-view",
        at: at_noon.call(first_activity_day)
      ),
      raw_event(
        device: device, type: "install", session_id: "later-install",
        at: at_noon.call(install_day)
      )
    ])
    Rails.cache.clear

    points = Analytics::OverviewStatsService.user_trends(
      @project.id, start_date: first_activity_day, end_date: install_day
    )[:points].index_by { |point| Date.parse(point[:date]) }
    card = Analytics::OverviewStatsService.key_metrics(
      @project.id, start_date: first_activity_day, end_date: install_day
    )

    assert_equal 1, card.dig(:metrics, :new_users)
    assert_equal 1, points.fetch(first_activity_day)[:new_users]
    assert_equal 0, points.fetch(install_day)[:new_users]
  end

  # --- Pass B: PG per-link counts with cross-link isolation -----------------

  test "event metrics query returns per-link counts from postgres without cross-link leakage" do
    link_a = links(:basic_link)
    link_b = links(:campaign_link)
    raws = []
    2.times { raws << fresh_event(type: "open", link: link_a) }
    4.times { raws << fresh_event(type: "view", link: link_a) }
    3.times { raws << fresh_event(type: "open", link: link_b) }
    ingest_via_process_batch(raws)

    m = EventMetricsQuery.new(project: @project)
                         .metrics_for_link_ids([link_a.id, link_b.id], @start_date, @end_date)
    assert_equal 2, m[link_a.id][:open]
    assert_equal 4, m[link_a.id][:view]
    assert_equal 3, m[link_b.id][:open]
    assert_equal 0, m[link_b.id][:view], "link_a views must not leak into link_b"
  end

  # --- Pass B: counter routing (MAPPING-divergence detector) ----------------
  # Asserts each event type lands in its own dashboard counter using explicit
  # hardcoded expectations (never Grovs::Events::MAPPING). Distinct, non-adjacent
  # counts per type so a routing bug (e.g. open incrementing installs) is caught,
  # not masked by equal counts.
  ROUTING_COUNTS = { "view" => 2, "open" => 3, "install" => 5, "reinstall" => 7, "app_open" => 11 }.freeze

  test "dashboard metrics routes each event type to its own counter" do
    ROUTING_COUNTS.each do |type, n|
      ingest_via_process_batch(Array.new(n) { fresh_event(type: type) })
    end
    DailyProjectMetricsGenerator.call(@today)

    current = dashboard_current
    # Distinct, non-adjacent counts so a cross-routing bug (e.g. open landing in
    # views) can't be masked. Independent hardcoded expectations, not MAPPING.
    assert_equal ROUTING_COUNTS["view"],     current[:views]
    assert_equal ROUTING_COUNTS["open"],     current[:opens]
    assert_equal ROUTING_COUNTS["app_open"], current[:app_opens]
    assert_equal ROUTING_COUNTS["reinstall"], current[:reinstalls]
    # Dashboard installs = installs + reinstalls — a reinstall counts as a total
    # install (daily_project_metrics_generator.rb:158 total_installs). Verified
    # in code, encoded here independently.
    assert_equal ROUTING_COUNTS["install"] + ROUTING_COUNTS["reinstall"], current[:installs]
  end

  # --- Pass B: CH-only event types never increment counters -----------------

  test "custom and screen_view are raw CH events but never increment counters" do
    link = links(:basic_link)
    3.times { ingest_via_process_batch([fresh_event(type: "custom", link: link)]) }
    2.times { ingest_via_process_batch([fresh_event(type: "screen_view", link: link)]) }

    assert_equal 3, volume_count("custom")
    assert_equal 2, volume_count("screen_view")

    # PG raw counters
    counters = EventMetricsQuery.new(project: @project)
                                .metrics_for_link_ids([link.id], @start_date, @end_date)[link.id] || {}
    assert_equal 0, counters[:view].to_i
    assert_equal 0, counters[:open].to_i

    # rolled-up dashboard counters must also stay zero
    DailyProjectMetricsGenerator.call(@today)
    current = dashboard_current
    assert_equal 0, current[:views]
    assert_equal 0, current[:opens]
    assert_equal 0, current[:installs]
  end

  # --- Pass C: sessions -----------------------------------------------------

  test "session build produces separate sessions per session_id with correct counts" do
    device, = make_visitor
    now = Time.current
    raws = []
    %w[open install app_open].each_with_index do |type, i|
      raws << raw_event(device: device, type: type, session_id: "s1", at: now + i)
    end
    %w[open install].each_with_index do |type, i|
      raws << raw_event(device: device, type: type, session_id: "s2", at: now + 10 + i)
    end
    ingest_via_process_batch(raws)

    SessionBuildJob.new.perform(lookback_days: 1)

    res = Analytics::SessionsQueryService.list(
      @project.id, start_date: @start_date, end_date: @end_date
    )
    assert_equal 2, res[:data].size, "two distinct session_ids -> two sessions"
    counts = res[:data].map { |r| (r["event_count"] || r[:event_count]).to_i }.sort
    assert_equal [2, 3], counts
  end

  # --- Pass B: retention (reduced scope) ------------------------------------
  # first_seen = visitor.created_at; day-1 retained iff an event exists on
  # first_seen + 1 day. One returner + one non-returner = a 50% cohort, which
  # (unlike a single-person 100%) catches an "everyone retained" false green.
  # Times pinned to midday UTC to avoid the toDate boundary.
  test "retention day_1 is 50% with one returner and one non-returner" do
    install_day = (@today - 2).to_time(:utc) + 12.hours
    return_day  = (@today - 1).to_time(:utc) + 12.hours

    returner_device, = make_visitor(created_at: install_day)
    ingest_via_process_batch([raw_event(device: returner_device, type: "open", session_id: "r1", at: return_day)])

    nonreturner_device, = make_visitor(created_at: install_day)
    ingest_via_process_batch([raw_event(device: nonreturner_device, type: "open", session_id: "n1", at: install_day)])

    res = Analytics::RetentionService.summary(@project.id)
    assert_equal 50.0, res[:day_1], "1 of 2 eligible visitors returned on day 1"
  end
end
