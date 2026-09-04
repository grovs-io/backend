# frozen_string_literal: true

# Multi-project isolation tests for ClickHouse.
#
# Each test targets a specific structural failure mode — not "does WHERE work?"
# but "would this break if someone removed project_id from an ORDER BY key,
# dropped it from a GROUP BY, or introduced shared state in the pipeline?"

require "test_helper"

class ClickhouseProjectIsolationTest < ActiveSupport::TestCase
  include ClickhouseTestHelper

  fixtures :instances, :projects, :devices, :visitors, :domains, :links

  PROJECT_A = 42
  PROJECT_B = 99

  setup do
    skip_unless_clickhouse!
    @ch_auto_rebuild_breakdowns = true
    @original_read_enabled = Rails.application.config.clickhouse_read_enabled
    Rails.application.config.clickhouse_read_enabled = true
  end

  teardown do
    Rails.application.config.clickhouse_read_enabled = @original_read_enabled if defined?(@original_read_enabled)
  end

  # --- helpers ---

  # Wait until ALTER TABLE DELETE mutations are physically applied.
  # Polls actual table data (system.mutations is_done is unreliable for timing).
  def wait_for_delete!(table, project_id, timeout: 30)
    pid = Integer(project_id)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    loop do
      cnt = Clickhouse.with { |c| c.select_value("SELECT count() FROM `#{table}` WHERE project_id = #{pid}") }
      return if cnt == 0
      if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        flunk "ALTER TABLE DELETE on #{table} for project #{project_id} did not complete within #{timeout}s"
      end
      sleep(0.5)
    end
  end

  def ts(date_str = '2026-05-01', hour = 12)
    Time.utc(*date_str.split('-').map(&:to_i), hour, 0, 0).strftime('%Y-%m-%d %H:%M:%S.000')
  end

  def insert_event(attrs = {})
    defaults = {
      project_id: PROJECT_A,
      event_type: 'view',
      device_id: 1,
      visitor_id: 1,
      link_id: 0,
      inviter_id: 0,
      campaign_id: 0,
      platform: 'ios',
      engagement_time: 0,
      country: 'US',
      created_at: ts
    }
    insert_ch_events(defaults.merge(attrs))
  end

  def insert_purchase(attrs = {})
    defaults = {
      project_id: PROJECT_A,
      event_type: 'buy',
      purchase_type: 'subscription',
      product_id: 'com.test.premium',
      usd_price_cents: 999,
      currency: 'USD',
      quantity: 1,
      transaction_id: "txn_#{SecureRandom.hex(4)}",
      original_transaction_id: 'orig_001',
      store_source: 'apple',
      device_id: 1,
      link_id: 0,
      visitor_id: 1,
      purchase_date: ts,
      created_at: ts
    }
    Clickhouse.with { |conn| conn.insert('purchase_events', [defaults.merge(attrs)]) }
  end

  def insert_profile(attrs = {})
    defaults = {
      project_id: PROJECT_A,
      visitor_id: 1,
      device_id: 1,
      platform: 'ios',
      country: 'US',
      city: '',
      first_seen: ts,
      last_seen: ts
    }
    Clickhouse.with { |conn| conn.insert('user_profiles', [defaults.merge(attrs)]) }
  end

  # =====================================================================
  # 1. ReplacingMergeTree: same transaction_id in different projects
  #    survives dedup (ORDER BY includes project_id)
  #
  #    Failure mode: if someone removes project_id from purchase_events
  #    ORDER BY (project_id, transaction_id, event_type), OPTIMIZE FINAL
  #    would merge rows across projects — one project's purchase vanishes.
  # =====================================================================

  test "same transaction_id in different projects survives ReplacingMergeTree FINAL" do
    shared_txn = "txn_shared_001"
    insert_purchase(project_id: PROJECT_A, transaction_id: shared_txn, usd_price_cents: 999)
    insert_purchase(project_id: PROJECT_B, transaction_id: shared_txn, usd_price_cents: 5000)

    # Force merge to trigger ReplacingMergeTree dedup
    Clickhouse.with { |conn| conn.execute("OPTIMIZE TABLE purchase_events FINAL") }

    rows = Clickhouse.with do |conn|
      conn.select_all("SELECT project_id, usd_price_cents FROM purchase_events FINAL ORDER BY project_id")
    end

    assert_equal 2, rows.size, "Both projects' purchases must survive FINAL — ORDER BY includes project_id"
    assert_equal PROJECT_A, rows[0]['project_id']
    assert_equal 999, rows[0]['usd_price_cents']
    assert_equal PROJECT_B, rows[1]['project_id']
    assert_equal 5000, rows[1]['usd_price_cents']
  end

  # =====================================================================
  # 2. unique_devices (uniqState) in project_daily is project-scoped
  #
  #    Failure mode: if MV GROUP BY lost project_id, uniqState(device_id)
  #    would merge device sets across projects — project A's unique count
  #    would include project B's devices.
  # =====================================================================

  test "unique_devices in project_daily are project-scoped" do
    # device 1 appears in both projects; device 2 only in B
    insert_event(project_id: PROJECT_A, device_id: 1)
    insert_event(project_id: PROJECT_B, device_id: 1)
    insert_event(project_id: PROJECT_B, device_id: 2)

    rows_a = ClickhouseReadService.project_daily_stats(
      PROJECT_A, start_date: '2026-05-01', end_date: '2026-05-01'
    )
    rows_b = ClickhouseReadService.project_daily_stats(
      PROJECT_B, start_date: '2026-05-01', end_date: '2026-05-01'
    )

    assert_equal 1, rows_a.first['unique_devices'],
      "Project A has 1 unique device — device 2 must not leak from B"
    assert_equal 2, rows_b.first['unique_devices'],
      "Project B has 2 unique devices"
  end

  # =====================================================================
  # 3. inviter_id SimpleAggregateFunction(max) in visitor_daily
  #    doesn't leak across projects
  #
  #    Failure mode: if ORDER BY lost project_id, AggregatingMergeTree
  #    would merge rows for the same visitor_id. max(inviter_id) would
  #    pick the larger inviter regardless of project — visitor A's
  #    referrer would be overwritten by B's.
  # =====================================================================

  test "visitor_daily inviter_id stays project-scoped with same visitor_id" do
    insert_event(project_id: PROJECT_A, visitor_id: 50, inviter_id: 100)
    insert_event(project_id: PROJECT_B, visitor_id: 50, inviter_id: 999)

    vd_a = Clickhouse.with do |conn|
      conn.select_all(
        "SELECT inviter_id_state FROM visitor_daily WHERE project_id = #{PROJECT_A} AND visitor_id = 50"
      )
    end
    vd_b = Clickhouse.with do |conn|
      conn.select_all(
        "SELECT inviter_id_state FROM visitor_daily WHERE project_id = #{PROJECT_B} AND visitor_id = 50"
      )
    end

    assert_equal 100, vd_a.first['inviter_id_state'],
      "Project A visitor's inviter must be 100, not 999 from project B"
    assert_equal 999, vd_b.first['inviter_id_state'],
      "Project B visitor's inviter must be 999"
  end

  # =====================================================================
  # 4. unique_visitors per country in project_country_daily
  #
  #    Failure mode: if MV GROUP BY lost project_id,
  #    uniqState(visitor_id) would merge visitor sets for same country
  #    across projects — shared visitors counted once globally.
  # =====================================================================

  test "unique_visitors per country is project-scoped in country_daily" do
    # visitor 10 visits US in both projects — should be 1 unique in each, not 1 total
    insert_event(project_id: PROJECT_A, visitor_id: 10, country: 'US')
    insert_event(project_id: PROJECT_A, visitor_id: 20, country: 'US')
    insert_event(project_id: PROJECT_B, visitor_id: 10, country: 'US')

    rows_a = ClickhouseReadService.project_country_daily_stats(
      PROJECT_A, start_date: '2026-05-01', end_date: '2026-05-01'
    )
    rows_b = ClickhouseReadService.project_country_daily_stats(
      PROJECT_B, start_date: '2026-05-01', end_date: '2026-05-01'
    )

    assert_equal 2, rows_a.first['unique_visitors'],
      "Project A has 2 unique US visitors (10 and 20)"
    assert_equal 1, rows_b.first['unique_visitors'],
      "Project B has 1 unique US visitor (10) — must not merge with A's set"
  end

  # =====================================================================
  # 5. top_links with limit: project B's high-traffic link can't push
  #    project A's links out of the top N
  #
  #    Failure mode: if the top_links query was missing project_id in
  #    the WHERE, project B's link (50 views) would outrank A's links
  #    and consume the LIMIT, making A's links disappear from results.
  # =====================================================================

  test "top_links limit is project-scoped: B's traffic can't push A's links out" do
    # Project A: 2 links with modest traffic
    2.times { insert_event(project_id: PROJECT_A, link_id: 100) }
    insert_event(project_id: PROJECT_A, link_id: 200)
    # Project B: 1 link with massive traffic
    50.times { insert_event(project_id: PROJECT_B, link_id: 300) }

    top_a = ClickhouseReadService.top_links(
      PROJECT_A, start_date: '2026-05-01', end_date: '2026-05-01', limit: 1
    )

    assert_equal 1, top_a.size
    assert_equal 100, top_a.first['link_id'],
      "Project A's top link should be 100 (2 views), not B's link 300 (50 views)"
    assert_equal 2, top_a.first['cnt']
  end

  # =====================================================================
  # 6. Delete project A's data, verify project B's MV aggregations intact
  #
  #    Failure mode: ALTER TABLE DELETE without project_id scoping, or
  #    MV corruption from mutations on shared partitions.
  # =====================================================================

  test "deleting project A events does not corrupt project B MV aggregations" do
    insert_event(project_id: PROJECT_A, visitor_id: 1, link_id: 100)
    insert_event(project_id: PROJECT_A, visitor_id: 2, link_id: 100)
    insert_event(project_id: PROJECT_B, visitor_id: 3, link_id: 200)
    insert_event(project_id: PROJECT_B, visitor_id: 4, link_id: 200)
    insert_event(project_id: PROJECT_B, visitor_id: 5, link_id: 200)

    # Snapshot B's state before deletion
    b_daily_before = ClickhouseReadService.project_daily_stats(
      PROJECT_B, start_date: '2026-05-01', end_date: '2026-05-01'
    )
    b_link_before = ClickhouseReadService.link_daily_stats(
      PROJECT_B, link_id: 200, start_date: '2026-05-01', end_date: '2026-05-01'
    )

    # Delete project A's events from the source table.
    # Use ALTER TABLE DELETE on just events (fast on plain MergeTree),
    # then TRUNCATE the MV targets scoped to project A is impossible,
    # so we do lightweight deletes on the two MV targets directly.
    Clickhouse.with do |conn|
      conn.execute("ALTER TABLE events DELETE WHERE project_id = #{PROJECT_A}")
      conn.execute("ALTER TABLE project_daily DELETE WHERE project_id = #{PROJECT_A}")
      conn.execute("ALTER TABLE link_daily DELETE WHERE project_id = #{PROJECT_A}")
    end
    wait_for_delete!('events', PROJECT_A)

    # Verify B's aggregations are unchanged
    b_daily_after = ClickhouseReadService.project_daily_stats(
      PROJECT_B, start_date: '2026-05-01', end_date: '2026-05-01'
    )
    b_link_after = ClickhouseReadService.link_daily_stats(
      PROJECT_B, link_id: 200, start_date: '2026-05-01', end_date: '2026-05-01'
    )

    assert_equal b_daily_before.first['cnt'], b_daily_after.first['cnt'],
      "Project B project_daily cnt must be unchanged after deleting A"
    assert_equal b_link_before.first['cnt'], b_link_after.first['cnt'],
      "Project B link_daily cnt must be unchanged after deleting A"
  end

  # =====================================================================
  # 7. Delete project A's purchases, verify B's revenue MV intact
  #
  #    Failure mode: ALTER TABLE DELETE on purchase_events corrupting
  #    purchase_project_daily or purchase_product_daily for other projects.
  # =====================================================================

  test "deleting project A purchases does not corrupt project B revenue MVs" do
    insert_purchase(project_id: PROJECT_A, usd_price_cents: 999, visitor_id: 1)
    insert_purchase(project_id: PROJECT_B, usd_price_cents: 5000, visitor_id: 2)
    insert_purchase(project_id: PROJECT_B, usd_price_cents: 3000, visitor_id: 3)

    b_revenue_before = ClickhouseReadService.purchase_project_daily_stats(
      PROJECT_B, start_date: '2026-05-01', end_date: '2026-05-01'
    )

    # Delete project A's purchases from source and MV target tables
    Clickhouse.with do |conn|
      conn.execute("ALTER TABLE purchase_events DELETE WHERE project_id = #{PROJECT_A}")
      conn.execute("ALTER TABLE purchase_project_daily DELETE WHERE project_id = #{PROJECT_A}")
      conn.execute("ALTER TABLE purchase_product_daily DELETE WHERE project_id = #{PROJECT_A}")
    end
    wait_for_delete!('purchase_events', PROJECT_A)

    b_revenue_after = ClickhouseReadService.purchase_project_daily_stats(
      PROJECT_B, start_date: '2026-05-01', end_date: '2026-05-01'
    )

    assert_equal b_revenue_before.first['total_revenue_cents'], b_revenue_after.first['total_revenue_cents'],
      "Project B revenue must be unchanged after deleting A's purchases"
    assert_equal b_revenue_before.first['units'], b_revenue_after.first['units']
  end

  # =====================================================================
  # 8. Interleaved inserts for two projects produce correct MV totals
  #
  #    Failure mode: if MV materialization had shared state (e.g. a
  #    running counter that doesn't reset per project), interleaved
  #    inserts could produce wrong aggregations.
  # =====================================================================

  test "interleaved inserts for two projects produce correct MV totals" do
    # Alternate between projects to stress any shared-state bugs
    insert_event(project_id: PROJECT_A, visitor_id: 1, engagement_time: 10)
    insert_event(project_id: PROJECT_B, visitor_id: 2, engagement_time: 20)
    insert_event(project_id: PROJECT_A, visitor_id: 3, engagement_time: 30)
    insert_event(project_id: PROJECT_B, visitor_id: 4, engagement_time: 40)
    insert_event(project_id: PROJECT_A, visitor_id: 5, engagement_time: 50)

    rows_a = ClickhouseReadService.project_daily_stats(
      PROJECT_A, start_date: '2026-05-01', end_date: '2026-05-01'
    )
    rows_b = ClickhouseReadService.project_daily_stats(
      PROJECT_B, start_date: '2026-05-01', end_date: '2026-05-01'
    )

    assert_equal 3, rows_a.first['cnt'], "Project A should have 3 events"
    assert_equal 90, rows_a.first['total_engagement_time'],
      "Project A engagement should be 10+30+50=90"
    assert_equal 3, rows_a.first['unique_visitors'],
      "Project A should have 3 unique visitors (1,3,5)"

    assert_equal 2, rows_b.first['cnt'], "Project B should have 2 events"
    assert_equal 60, rows_b.first['total_engagement_time'],
      "Project B engagement should be 20+40=60"
    assert_equal 2, rows_b.first['unique_visitors'],
      "Project B should have 2 unique visitors (2,4)"
  end

  # =====================================================================
  # 9. link_daily MV: same link_id in different projects stays isolated
  #    (SummingMergeTree ORDER BY includes project_id)
  #
  #    Failure mode: SummingMergeTree auto-sums rows with matching keys.
  #    If project_id were missing from ORDER BY, cnt for the same link_id
  #    across projects would be summed together.
  # =====================================================================

  test "link_daily SummingMergeTree keeps same link_id separate across projects" do
    insert_event(project_id: PROJECT_A, link_id: 100)
    insert_event(project_id: PROJECT_A, link_id: 100)
    insert_event(project_id: PROJECT_B, link_id: 100)

    rows_a = ClickhouseReadService.link_daily_stats(
      PROJECT_A, link_id: 100, start_date: '2026-05-01', end_date: '2026-05-01'
    )
    rows_b = ClickhouseReadService.link_daily_stats(
      PROJECT_B, link_id: 100, start_date: '2026-05-01', end_date: '2026-05-01'
    )

    assert_equal 2, rows_a.first['cnt'],
      "Project A link 100 cnt must be 2, not 3 (would be 3 if SummingMergeTree merged across projects)"
    assert_equal 1, rows_b.first['cnt'],
      "Project B link 100 cnt must be 1"
  end

  # =====================================================================
  # 10. purchase_product_daily: same product_id in different projects
  #     (ReplacingMergeTree ORDER BY includes project_id)
  #
  #     Failure mode: cross-project leakage would sum revenue across
  #     projects for the same product_id.
  # =====================================================================

  test "purchase_product_daily keeps same product_id separate across projects" do
    insert_purchase(project_id: PROJECT_A, product_id: 'premium', usd_price_cents: 999)
    insert_purchase(project_id: PROJECT_B, product_id: 'premium', usd_price_cents: 2000)

    rows_a = ClickhouseReadService.purchase_product_daily_stats(
      PROJECT_A, product_id: 'premium', start_date: '2026-05-01', end_date: '2026-05-01'
    )
    rows_b = ClickhouseReadService.purchase_product_daily_stats(
      PROJECT_B, product_id: 'premium', start_date: '2026-05-01', end_date: '2026-05-01'
    )

    assert_equal 999, rows_a.first['total_revenue_cents'],
      "Project A premium revenue must be 999, not 2999 (would be 2999 if rollup merged across projects)"
    assert_equal 2000, rows_b.first['total_revenue_cents']
  end

  # =====================================================================
  # 11. user_profiles ReplacingMergeTree: same visitor_id in different
  #     projects survives FINAL (ORDER BY includes project_id)
  #
  #     Failure mode: if project_id were removed from ORDER BY
  #     (project_id, visitor_id), FINAL would merge profiles for the
  #     same visitor across projects — one profile overwritten.
  # =====================================================================

  test "user_profiles FINAL keeps same visitor_id separate across projects" do
    insert_profile(project_id: PROJECT_A, visitor_id: 1, country: 'US',
                   last_seen: ts('2026-05-01', 10))
    insert_profile(project_id: PROJECT_B, visitor_id: 1, country: 'JP',
                   last_seen: ts('2026-05-01', 14))

    Clickhouse.with { |conn| conn.execute("OPTIMIZE TABLE user_profiles FINAL") }

    profiles = Clickhouse.with do |conn|
      conn.select_all("SELECT project_id, country FROM user_profiles FINAL ORDER BY project_id")
    end

    assert_equal 2, profiles.size,
      "Both profiles must survive FINAL — ORDER BY includes project_id"
    assert_equal 'US', profiles.find { |r| r['project_id'] == PROJECT_A }['country']
    assert_equal 'JP', profiles.find { |r| r['project_id'] == PROJECT_B }['country']
  end

  # =====================================================================
  # 12. unique_visitors (uniqMerge) in project_daily
  #
  #     Failure mode: if MV GROUP BY lost project_id,
  #     uniqState(visitor_id) merges visitor sets globally — shared
  #     visitor counted once instead of once per project.
  # =====================================================================

  test "unique_visitors in project_daily are project-scoped" do
    insert_event(project_id: PROJECT_A, visitor_id: 10)
    insert_event(project_id: PROJECT_A, visitor_id: 20)
    insert_event(project_id: PROJECT_B, visitor_id: 10) # shared visitor
    insert_event(project_id: PROJECT_B, visitor_id: 30)
    insert_event(project_id: PROJECT_B, visitor_id: 40)

    rows_a = ClickhouseReadService.project_daily_stats(
      PROJECT_A, start_date: '2026-05-01', end_date: '2026-05-01'
    )
    rows_b = ClickhouseReadService.project_daily_stats(
      PROJECT_B, start_date: '2026-05-01', end_date: '2026-05-01'
    )

    assert_equal 2, rows_a.first['unique_visitors'],
      "Project A has 2 unique visitors (10,20) — visitor 10 in B must not reduce this"
    assert_equal 3, rows_b.first['unique_visitors'],
      "Project B has 3 unique visitors (10,30,40)"
  end

  # =====================================================================
  # 13. paying_visitors (uniqMerge) in purchase_project_daily
  #
  #     Failure mode: same as unique_visitors but for purchase MV.
  #     uniqState(visitor_id) would merge paying visitor sets globally.
  # =====================================================================

  test "paying_visitors in purchase_project_daily are project-scoped" do
    insert_purchase(project_id: PROJECT_A, visitor_id: 10)
    insert_purchase(project_id: PROJECT_A, visitor_id: 20)
    insert_purchase(project_id: PROJECT_A, visitor_id: 10) # dup within A
    insert_purchase(project_id: PROJECT_B, visitor_id: 10) # shared visitor_id

    rows_a = ClickhouseReadService.purchase_project_daily_stats(
      PROJECT_A, start_date: '2026-05-01', end_date: '2026-05-01'
    )
    rows_b = ClickhouseReadService.purchase_project_daily_stats(
      PROJECT_B, start_date: '2026-05-01', end_date: '2026-05-01'
    )

    assert_equal 2, rows_a.first['paying_visitors'],
      "Project A has 2 paying visitors (10,20) — dup and B's visitor 10 must not affect this"
    assert_equal 1, rows_b.first['paying_visitors']
  end

  # =====================================================================
  # 14. Write pipeline: batch with mixed projects lands correctly
  #
  #     Failure mode: if build_clickhouse_row cached/shared state across
  #     events (e.g. geo_lookup, visitor_id resolution), project_id from
  #     one event could bleed into another.
  # =====================================================================

  test "pipeline batch with mixed projects writes correct project_id per event" do
    @original_ch_enabled = Rails.application.config.clickhouse_write_enabled
    Rails.application.config.clickhouse_write_enabled = true

    project_a = projects(:one)
    project_b = projects(:two)
    device = devices(:ios_device)
    # ios_device has no project-B visitor; without one the payload would be parked.
    Visitor.create!(device: device, project: project_b)

    event_a = {
      type: Grovs::Events::OPEN, project_id: project_a.id, device_id: device.id,
      data: nil, link_id: nil, engagement_time: nil, created_at: 1.hour.from_now.iso8601
    }.to_json
    event_b = {
      type: Grovs::Events::APP_OPEN, project_id: project_b.id, device_id: device.id,
      data: nil, link_id: nil, engagement_time: nil, created_at: 1.hour.from_now.iso8601
    }.to_json

    job = BatchEventProcessorJob.new
    job.jid = "isolation-test-#{SecureRandom.hex(4)}"

    job.send(:process_batch, [event_a, event_b])
    rebuild_ch_breakdowns!

    ch_a = ch_select_events(project_a.id)
    ch_b = ch_select_events(project_b.id)

    assert_equal 1, ch_a.size
    assert_equal Grovs::Events::OPEN, ch_a.first['event_type']
    assert_equal project_a.id, ch_a.first['project_id']

    assert_equal 1, ch_b.size
    assert_equal Grovs::Events::APP_OPEN, ch_b.first['event_type']
    assert_equal project_b.id, ch_b.first['project_id']
  ensure
    Rails.application.config.clickhouse_write_enabled = @original_ch_enabled if defined?(@original_ch_enabled)
    REDIS.with do |conn|
      conn.del(BatchEventProcessorJob::REDIS_KEY)
      conn.del("events:processing:#{job.jid}") if job
      conn.del("events:heartbeat:#{job.jid}") if job
      keys = conn.keys("#{BatchEventProcessorJob::CH_BATCH_DONE_PREFIX}:*")
      conn.del(*keys) if keys.any?
    end
  end

  # =====================================================================
  # 15. Write pipeline: MVs partition correctly across projects in batch
  #
  #     Failure mode: MV materialization on a multi-project batch could
  #     sum counts globally if GROUP BY were wrong, or if the insert
  #     batching grouped rows incorrectly.
  # =====================================================================

  test "pipeline batch MVs aggregate per-project correctly" do
    @original_ch_enabled = Rails.application.config.clickhouse_write_enabled
    Rails.application.config.clickhouse_write_enabled = true

    project_a = projects(:one)
    project_b = projects(:two)
    device = devices(:ios_device)
    # ios_device has no project-B visitor; without one the payload would be parked.
    Visitor.create!(device: device, project: project_b)

    # Distinct created_at per event so each is a distinct canonical event (identical
    # content would collapse under FINAL — dedup, not an isolation concern).
    events = []
    3.times do |i|
      events << { type: Grovs::Events::APP_OPEN, project_id: project_a.id, device_id: device.id,
                  data: nil, link_id: nil, engagement_time: nil, created_at: (1.hour.from_now + i.seconds).iso8601 }.to_json
    end
    2.times do |i|
      events << { type: Grovs::Events::APP_OPEN, project_id: project_b.id, device_id: device.id,
                  data: nil, link_id: nil, engagement_time: nil, created_at: (1.hour.from_now + i.seconds).iso8601 }.to_json
    end

    job = BatchEventProcessorJob.new
    job.jid = "isolation-mv-test-#{SecureRandom.hex(4)}"

    job.send(:process_batch, events)
    rebuild_ch_breakdowns!

    pd_a = ch_query('project_daily', project_a.id)
    pd_b = ch_query('project_daily', project_b.id)

    assert_equal 3, pd_a.sum { |r| r['cnt'] },
      "project_daily for A should be 3, not 5 (would be 5 if MV merged both projects)"
    assert_equal 2, pd_b.sum { |r| r['cnt'] },
      "project_daily for B should be 2"
  ensure
    Rails.application.config.clickhouse_write_enabled = @original_ch_enabled if defined?(@original_ch_enabled)
    REDIS.with do |conn|
      conn.del(BatchEventProcessorJob::REDIS_KEY)
      conn.del("events:processing:#{job.jid}") if job
      conn.del("events:heartbeat:#{job.jid}") if job
      keys = conn.keys("#{BatchEventProcessorJob::CH_BATCH_DONE_PREFIX}:*")
      conn.del(*keys) if keys.any?
    end
  end
end
