# frozen_string_literal: true

require "test_helper"
require_relative "../auth_test_helper"
require_relative "scenario_dsl"

# High volume: thousands of seeded events through process_batch in chunks,
# reconciled in aggregate across PG, CH events, and the project_daily rollup.
# Scale via HIGH_VOLUME_EVENTS (default 5000, clamped to a multi-chunk minimum).
class HighVolumeTest < ActionDispatch::IntegrationTest
  include AuthTestHelper
  include ClickhouseTestHelper
  include AnalyticsMatrix::ScenarioDSL

  fixtures :instances, :projects, :devices, :visitors, :domains, :redirect_configs

  SEED = 20_260_624
  # NON-VIEW types for the bulk run so intra-batch dedup can't reduce the count;
  # VIEW dedup is exercised on its own below.
  EVENT_TYPES = %w[open install app_open reactivation].freeze
  PLATFORMS   = %w[ios android web].freeze
  POOL_PER_PLATFORM = 8
  CHUNK = 500
  MIN_EVENTS = 1_500 # > 2 chunks: guarantees the chunk-boundary path runs

  def volume_n
    [(ENV["HIGH_VOLUME_EVENTS"] || 5000).to_i, MIN_EVENTS].max
  end

  setup do
    matrix_setup!
    @project = projects(:one)
    @start_date = Date.current - 1
    @end_date   = Date.current + 1
    # PG ships with fixture events for project one; CH is truncated but PG isn't.
    # Clear so Event.count reflects only what this test ingests (rolled back).
    Event.where(project_id: @project.id).delete_all
    @pool = PLATFORMS.index_with do |platform|
      Array.new(POOL_PER_PLATFORM) { build_device(platform) }
    end
  end

  teardown { matrix_teardown! }

  def build_device(platform, with_visitor: true)
    device = Device.create!(
      user_agent: "hv", ip: "1.1.1.1", remote_ip: "2.2.2.2",
      platform: platform, vendor: "hv-#{SecureRandom.hex(6)}"
    )
    if with_visitor
      Visitor.create!(
        project: @project, device: device, web_visitor: false,
        sdk_identifier: "hv-#{SecureRandom.hex(4)}", uuid: SecureRandom.uuid
      )
    end
    device
  end

  def raw_event(device:, type:, session_id:, platform: nil)
    {
      type: type, project_id: @project.id, device_id: device.id, link_id: nil,
      data: nil, engagement_time: nil, created_at: Time.current.utc.iso8601(3),
      event_name: "", session_id: session_id, tags: []
    }.to_json
  end

  def ch_uniq_sessions
    Clickhouse.with do |c|
      c.select_value("SELECT uniqExact(session_id) FROM events WHERE project_id = #{@project.id}").to_i
    end
  end

  def ch_group_by_type_platform
    rows = Clickhouse.with do |c|
      c.select_all(
        "SELECT event_type, platform, count() AS n FROM events " \
        "WHERE project_id = #{@project.id} GROUP BY event_type, platform"
      ).to_a
    end
    rows.to_h { |r| [[r["event_type"], r["platform"]], r["n"].to_i] }
  end

  def project_daily_by_type_platform
    rows = Clickhouse.with do |c|
      c.select_all(
        "SELECT event_type, platform, sum(cnt) AS total FROM project_daily " \
        "WHERE project_id = #{@project.id} GROUP BY event_type, platform"
      ).to_a
    end
    rows.to_h { |r| [[r["event_type"], r["platform"]], r["total"].to_i] }
  end

  test "high-volume aggregate counts reconcile across PG, CH events, and the project_daily rollup" do
    n = volume_n
    assert_operator n, :>, CHUNK, "must span multiple chunks to exercise boundaries"

    rng = Random.new(SEED)
    by_tp = Hash.new(0) # keyed [type, platform] — keeps the platform dimension
    touched = Hash.new { |h, k| h[k] = Set.new } # distinct devices (==visitors) per platform
    raws = Array.new(n) do |i|
      platform = PLATFORMS[rng.rand(PLATFORMS.size)]
      type     = EVENT_TYPES[rng.rand(EVENT_TYPES.size)]
      device   = @pool[platform][rng.rand(POOL_PER_PLATFORM)]
      by_tp[[type, platform]] += 1
      touched[platform] << device.id
      raw_event(device: device, type: type, session_id: "hv-#{i}")
    end
    ingest_via_process_batch(raws, chunk: CHUNK)

    # Totals AND identities: each event has a unique session id, so a boundary
    # bug that drops one event and replays another (same totals) is still caught
    # by the distinct-session-id count.
    assert_equal n, Event.where(project_id: @project.id).count, "PG total"
    assert_equal n, Event.where(project_id: @project.id).distinct.count(:session_id), "PG distinct sessions"
    assert_equal n, ch_event_count(@project.id), "CH events total"
    assert_equal n, ch_uniq_sessions, "CH distinct sessions"

    # Per-(type, platform) for raw events AND the project_daily rollup. Grouping
    # by both dimensions catches a platform-collapse bug a per-type-only check
    # would miss. project_daily is AggregatingMergeTree — sum(cnt) merges the
    # SimpleAggregateFunction state correctly.
    expected = by_tp.transform_keys { |type, platform| [type, platform] }
    assert_equal expected, ch_group_by_type_platform, "CH per (type, platform)"
    assert_equal expected, project_daily_by_type_platform, "project_daily per (type, platform)"

    # uniqMerge(visitors_state) is the AggregateFunction column that genuinely
    # requires merging uniq state across parts/chunks (the real MV-at-scale
    # check the design named). cnt is SimpleAggregateFunction(sum) so plain sum
    # above is correct; visitors_state needs uniqMerge. One visitor per device,
    # so distinct visitors per platform == distinct devices touched.
    uniq_rows = Clickhouse.with do |c|
      c.select_all(
        "SELECT platform, uniqMerge(visitors_state) AS u FROM project_daily " \
        "WHERE project_id = #{@project.id} GROUP BY platform"
      ).to_a
    end
    uniq = uniq_rows.to_h { |r| [r["platform"], r["u"].to_i] }
    touched.each do |platform, device_ids|
      assert_equal device_ids.size, uniq[platform], "uniqMerge visitors for #{platform}"
    end
  end

  test "replaying an identical batch does not double-count CH (event_id dedup)" do
    device = @pool["ios"].first
    slice = Array.new(3) { |i| raw_event(device: device, type: "open", session_id: "rp-#{i}") }

    ingest_via_process_batch(slice)
    assert_equal 3, ch_event_count(@project.id, event_type: "open")

    # Replay the IDENTICAL slice: same content -> same deterministic event_id -> the
    # ReplacingMergeTree collapses the replay (FINAL), so the logical count is unchanged.
    ingest_via_process_batch(slice)
    assert_equal 3, ch_event_count(@project.id, event_type: "open"),
                 "identical batch replay must not double-count ClickHouse (event_id dedup)"
  end

  test "intra-batch VIEW dedup keeps exactly one view per device" do
    dup_device = @pool["ios"].first
    distinct = [@pool["android"].first, @pool["web"].first]

    raws = []
    5.times { |i| raws << raw_event(device: dup_device, type: "view", session_id: "dup-#{i}") }
    distinct.each_with_index { |d, i| raws << raw_event(device: d, type: "view", session_id: "dist-#{i}") }
    ingest_via_process_batch(raws)

    assert_equal 3, ch_event_count(@project.id, event_type: "view"), "dedup-adjusted total"
    dup_rows = ch_query("events", @project.id, extra_where: "event_type = 'view' AND device_id = #{dup_device.id}")
    assert_equal 1, dup_rows.size, "exactly one view kept for the duplicated device"
  end

  test "cross-batch VIEW dedup within the 5s window skips duplicate views" do
    device = @pool["ios"].first
    # Two SEPARATE process_batch calls, no Redis flush between (flush is per-test
    # only), so the dedup key set by batch 1 is still live for batch 2.
    ingest_via_process_batch([raw_event(device: device, type: "view", session_id: "cb-1")])
    assert_equal 1, ch_event_count(@project.id, event_type: "view")

    ingest_via_process_batch([raw_event(device: device, type: "view", session_id: "cb-2")])
    assert_equal 1, ch_event_count(@project.id, event_type: "view"),
                 "second view for the same device within the TTL must be skipped"
  end

  test "high-volume parks visitorless events and reconciles unknown-platform events" do
    novisitor = Array.new(4) { build_device("ios", with_visitor: false) }
    unknown   = Array.new(4) { build_device("unknown") } # has a visitor, odd platform

    rng = Random.new(SEED + 1)
    n = 600
    raws = Array.new(n) do |i|
      device = i.even? ? novisitor[rng.rand(4)] : unknown[rng.rand(4)]
      raw_event(device: device, type: "open", session_id: "hvx-#{i}")
    end
    ingest_via_process_batch(raws, chunk: CHUNK)

    mine = Event.where(project_id: @project.id).where("session_id LIKE 'hvx-%'")
    assert_equal n / 2, mine.count, "only unknown-platform events persist to PG"
    assert_equal n / 2, ch_event_count(@project.id), "and to CH"
    assert_equal n / 2, REDIS.with { |conn| conn.llen(BatchEventProcessorJob::INTEGRITY_DLQ_KEY) },
      "all visitorless events must be parked"
    assert_equal 0, ch_query("events", @project.id, extra_where: "visitor_id = 0").size,
      "no CH visitor_id=0 rows may be written"
    assert_operator ch_query("events", @project.id, extra_where: "platform = 'unknown'").size, :>=, n / 2
  end
end
