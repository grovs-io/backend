# frozen_string_literal: true

require "test_helper"
require_relative "../auth_test_helper"
require_relative "scenario_dsl"

# Cross-project isolation: two projects' events ingested interleaved in one
# process_batch; each project's analytics must report exactly its own counts.
class CrossProjectIsolationTest < ActionDispatch::IntegrationTest
  include AuthTestHelper
  include ClickhouseTestHelper
  include AnalyticsMatrix::ScenarioDSL

  fixtures :instances, :projects, :devices, :visitors, :domains, :redirect_configs,
           :campaigns, :links

  setup do
    matrix_setup!
    @p1 = projects(:one)
    @p2 = projects(:two)
    @start_date = Date.current - 1
    @end_date   = Date.current + 1
    [VisitorDailyStatistic, LinkDailyStatistic, DailyProjectMetric].each do |model|
      model.where(project_id: [@p1.id, @p2.id]).delete_all
    end
  end

  teardown { matrix_teardown! }

  def device_for(project)
    device = Device.create!(
      user_agent: "iso", ip: "1.1.1.1", remote_ip: "2.2.2.2",
      platform: "ios", vendor: "ix-#{SecureRandom.hex(6)}"
    )
    Visitor.create!(
      project: project, device: device, web_visitor: false,
      sdk_identifier: "ix-#{SecureRandom.hex(4)}", uuid: SecureRandom.uuid
    )
    device
  end

  def raw_event(project:, device:, type:, session_id:, link: nil)
    {
      type: type, project_id: project.id, device_id: device.id, link_id: link&.id,
      data: nil, engagement_time: nil, created_at: Time.current.utc.iso8601(3),
      event_name: "", session_id: session_id, tags: []
    }.to_json
  end

  def volume(project, event_type)
    res = Analytics::EventsQueryService.volume(
      project.id, start_date: @start_date, end_date: @end_date,
      filters: [{ "field" => "event_type", "operator" => "is", "value" => event_type }]
    )
    res[:buckets].sum { |b| (b["count"] || b[:count]).to_i }
  end

  # Fresh device per event so VIEW dedup (per project+device) can't confound the
  # isolation counts.
  def event_for(project, type)
    raw_event(project: project, device: device_for(project), type: type,
              session_id: "#{project.id}-#{type}-#{SecureRandom.hex(4)}")
  end

  test "interleaved ingestion keeps each project's per-type metrics isolated" do
    raws = []
    3.times { raws << event_for(@p1, "open") }
    2.times { raws << event_for(@p1, "view") }
    5.times { raws << event_for(@p2, "open") }
    4.times { raws << event_for(@p2, "install") }
    raws.shuffle!(random: Random.new(20260624)) # actually interleave the two projects
    ingest_via_process_batch(raws) # one batch, both projects mixed

    # Each project sees ONLY its own counts.
    assert_equal 3, volume(@p1, "open")
    assert_equal 2, volume(@p1, "view")
    assert_equal 0, volume(@p1, "install"), "p2's installs must not leak into p1"

    assert_equal 5, volume(@p2, "open")
    assert_equal 4, volume(@p2, "install")
    assert_equal 0, volume(@p2, "view"), "p1's views must not leak into p2"

    assert_equal 5, ch_query("events", @p1.id).size
    assert_equal 9, ch_query("events", @p2.id).size

    # Unscoped partition probe: assert the rows exist ONLY under p1/p2 and in the
    # right counts. (A project-scoped ch_query can't catch a write that stamps a
    # third/foreign project_id — this can.)
    rows = Clickhouse.with { |c| c.select_all("SELECT project_id, count() AS n FROM events GROUP BY project_id").to_a }
    partitions = rows.to_h { |r| [r["project_id"].to_i, r["n"].to_i] }
    assert_equal({ @p1.id => 5, @p2.id => 9 }, partitions, "events must exist only under p1/p2")
  end

  # Negative control. Spec decided up front: an event is attributed to its
  # DECLARED project (project_id), never to the owning project of a link it
  # happens to reference. So a p1 event carrying a p2 link must NOT appear in any
  # p2-scoped metric, and must NOT inflate p2's metrics for that link.
  test "an event referencing another project's link never leaks into that project" do
    d1 = device_for(@p1)
    foreign_link = links(:second_link)
    # Precondition: the probe is only meaningful if the link really belongs to p2.
    assert_equal @p2.id, foreign_link.domain.project_id, "fixture must be a project-two link"

    ingest_via_process_batch([
      raw_event(project: @p1, device: d1, type: "open", session_id: "neg-1", link: foreign_link)
    ])

    assert_equal 1, volume(@p1, "open"), "event belongs to its declared project"
    assert_equal 0, volume(@p2, "open"), "cross-project link must not pull the event into p2"

    # CH link rollup (link_daily MV) is keyed by the event's project, not the
    # link's owner — so (before any legit p2 event) p2's link_daily stays empty
    # while p1's owns the row.
    assert_empty ch_query("link_daily", @p2.id), "foreign event must not appear in p2's link_daily"
    assert_equal 1, ch_query("link_daily", @p1.id).size, "p1 should own the link_daily row"
    assert_equal 0, (EventMetricsQuery.new(project: @p2)
                       .metrics_for_link_ids([foreign_link.id], @start_date, @end_date)[foreign_link.id] || {})[:open].to_i,
                 "foreign event must not inflate p2's PG metrics for its own link"

    # Positive control: a LEGITIMATE p2 event on the same link DOES count for p2,
    # proving the 0 above is project isolation, not a query that finds nothing.
    ingest_via_process_batch([
      raw_event(project: @p2, device: device_for(@p2), type: "open", session_id: "pos-1", link: foreign_link)
    ])
    p2_link = EventMetricsQuery.new(project: @p2)
                               .metrics_for_link_ids([foreign_link.id], @start_date, @end_date)
    assert_equal 1, (p2_link[foreign_link.id] || {})[:open].to_i,
                 "the legit p2 event counts; the p1 foreign event does not (== 1, not 2)"
  end

  test "distinct-visitor and session readers are isolated per project" do
    # p1: 2 distinct visitors; p2: 3 distinct visitors. Different counts so a
    # dropped project_id (which would report 5 for each) is caught.
    raws = []
    2.times { raws << event_for(@p1, "open") }
    3.times { raws << event_for(@p2, "open") }
    # one session per project (distinct session_id), each 2 events on one visitor
    ds1 = device_for(@p1)
    ds2 = device_for(@p2)
    raws << raw_event(project: @p1, device: ds1, type: "open",    session_id: "p1s")
    raws << raw_event(project: @p1, device: ds1, type: "install", session_id: "p1s")
    raws << raw_event(project: @p2, device: ds2, type: "open",    session_id: "p2s")
    raws << raw_event(project: @p2, device: ds2, type: "install", session_id: "p2s")
    ingest_via_process_batch(raws)

    # distinct-visitor source breakdown (Organic): p1 = 3 (2 + session visitor), p2 = 4
    s1 = Analytics::OverviewStatsService.sources_breakdown(@p1.id, start_date: @start_date, end_date: @end_date)
    s2 = Analytics::OverviewStatsService.sources_breakdown(@p2.id, start_date: @start_date, end_date: @end_date)
    assert_equal 3, s1[:sources].find { |s| s[:name] == "Organic" }[:value]
    assert_equal 4, s2[:sources].find { |s| s[:name] == "Organic" }[:value]

    # sessions: each event_for open is its own session (unique session_id) plus
    # the one multi-event session per project -> p1 = 3, p2 = 4. A leak would
    # report 7 for both.
    SessionBuildJob.new.perform(lookback_days: 1)
    l1 = Analytics::SessionsQueryService.list(@p1.id, start_date: @start_date, end_date: @end_date)
    l2 = Analytics::SessionsQueryService.list(@p2.id, start_date: @start_date, end_date: @end_date)
    assert_equal 3, l1[:data].size, "p1 sees only its own sessions"
    assert_equal 4, l2[:data].size, "p2 sees only its own sessions"
  end

  test "dashboard metrics are isolated per project" do
    raws = []
    3.times { raws << event_for(@p1, "open") }
    5.times { raws << event_for(@p2, "open") }
    ingest_via_process_batch(raws)
    DailyProjectMetricsGenerator.call(Date.current) # processes all projects for the date

    p1 = DashboardMetrics.call(project_id: @p1.id, start_time: @start_date, end_time: @end_date)[:current]
    p2 = DashboardMetrics.call(project_id: @p2.id, start_time: @start_date, end_time: @end_date)[:current]
    assert_equal 3, p1[:opens]
    assert_equal 5, p2[:opens]
    # cross-type isolation: p2-only installs must not surface in p1's dashboard
    assert_equal 0, p1[:installs], "p2 had no installs here, p1 must read 0"
    assert_equal 0, p2[:installs]
  end

  # top_links is the leak surface the design doc names explicitly ("two's link
  # ids never appear in one's top_links"). An install on a p2 link must rank for
  # p2 and never surface in p1's top_links.
  test "top_links never surfaces another project's links" do
    p1_link = links(:basic_link)  # project one
    p2_link = links(:second_link) # project two
    assert_equal @p1.id, p1_link.domain.project_id
    assert_equal @p2.id, p2_link.domain.project_id

    ingest_via_process_batch([
      raw_event(project: @p1, device: device_for(@p1), type: "install", session_id: "tl-p1", link: p1_link),
      raw_event(project: @p2, device: device_for(@p2), type: "install", session_id: "tl-p2", link: p2_link)
    ])

    p1_top = TopLinksAnalytics.new(project_id: @p1.id, platform: nil, start_time: @start_date, end_time: @end_date).call
    p2_top = TopLinksAnalytics.new(project_id: @p2.id, platform: nil, start_time: @start_date, end_time: @end_date).call

    # Identify by path (Link has no hashid here; :path is a stable serializer field).
    p1_paths = p1_top.map { |l| l[:path] || l["path"] }
    p2_paths = p2_top.map { |l| l[:path] || l["path"] }
    assert_includes p2_paths, p2_link.path, "p2's link should rank in p2's own top_links"
    refute_includes p1_paths, p2_link.path, "p2's link must never appear in p1's top_links"
  end
end
