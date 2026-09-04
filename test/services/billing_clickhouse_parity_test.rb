# frozen_string_literal: true

require "test_helper"

class BillingClickhouseParityTest < ActiveSupport::TestCase
  include ClickhouseTestHelper

  fixtures :instances, :projects, :devices, :visitors

  setup do
    skip_unless_clickhouse!

    @instance = instances(:one)
    @production = projects(:one)
    @test_project = projects(:one_test)
    @service = ProjectService.new

    @original_ch_write = Rails.application.config.clickhouse_write_enabled
    @original_ch_read = Rails.application.config.clickhouse_read_enabled
    Rails.application.config.clickhouse_write_enabled = true
    Rails.application.config.clickhouse_read_enabled = true

    Rails.cache.clear
    VisitorDailyStatistic.where(project_id: billing_project_ids).delete_all
    flush_billing_redis!
  end

  teardown do
    Rails.application.config.clickhouse_write_enabled = @original_ch_write if defined?(@original_ch_write)
    Rails.application.config.clickhouse_read_enabled = @original_ch_read if defined?(@original_ch_read)
    flush_billing_redis!
  end

  test "single-month billing window matches Postgres across production and test projects" do
    prod_device_a, = make_device(project: @production, platform: "ios", tag: "prod-a")
    prod_device_b, = make_device(project: @production, platform: "android", tag: "prod-b")
    test_device_a, = make_device(project: @test_project, platform: "ios", tag: "test-a")

    ingest_billing_events([
      raw_event(project: @production, device: prod_device_a, type: Grovs::Events::OPEN, at: Time.utc(2026, 5, 1, 10), session_id: "may-prod-a-1"),
      raw_event(project: @production, device: prod_device_a, type: Grovs::Events::VIEW, at: Time.utc(2026, 5, 2, 10), session_id: "may-prod-a-2"),
      raw_event(project: @production, device: prod_device_b, type: Grovs::Events::INSTALL, at: Time.utc(2026, 5, 31, 23, 59), session_id: "may-prod-b"),
      raw_event(project: @test_project, device: test_device_a, type: Grovs::Events::APP_OPEN, at: Time.utc(2026, 5, 15, 12), session_id: "may-test-a")
    ])

    assert_billing_parity Date.new(2026, 5, 1), Date.new(2026, 5, 31), expected: 3
  end

  test "multi-month billing window sums monthly MAUs like current Stripe billing" do
    device_a, = make_device(project: @production, platform: "ios", tag: "multi-a")
    device_b, = make_device(project: @production, platform: "android", tag: "multi-b")

    ingest_billing_events([
      raw_event(project: @production, device: device_a, type: Grovs::Events::OPEN, at: Time.utc(2026, 1, 10), session_id: "jan-a"),
      raw_event(project: @production, device: device_a, type: Grovs::Events::VIEW, at: Time.utc(2026, 2, 10), session_id: "feb-a"),
      raw_event(project: @production, device: device_b, type: Grovs::Events::OPEN, at: Time.utc(2026, 2, 11), session_id: "feb-b")
    ])

    start_date = Date.new(2026, 1, 1)
    end_date = Date.new(2026, 2, 28)

    assert_equal 3, @service.compute_maus_per_month_total(@instance, start_date, end_date)
    assert_equal @service.compute_maus_per_month_total(@instance, start_date, end_date),
      ch_monthly_total_for(start_date, end_date)
  end

  test "billing ignores traffic from projects outside the billed instance" do
    billed_device, = make_device(project: @production, platform: "ios", tag: "billed-instance")
    noise_device, = make_device(project: projects(:two), platform: "android", tag: "noise-project")

    ingest_billing_events([
      raw_event(project: @production, device: billed_device, type: Grovs::Events::OPEN, at: Time.utc(2026, 5, 10), session_id: "billed-open"),
      raw_event(project: projects(:two), device: noise_device, type: Grovs::Events::OPEN, at: Time.utc(2026, 5, 10), session_id: "noise-open")
    ])

    assert_billing_parity Date.new(2026, 5, 1), Date.new(2026, 5, 31), expected: 1
  end

  test "within-month multi-day activity counts one MAU for that month" do
    device, = make_device(project: @production, platform: "ios", tag: "same-month-repeat")

    ingest_billing_events([
      raw_event(project: @production, device: device, type: Grovs::Events::OPEN, at: Time.utc(2026, 5, 1), session_id: "repeat-may-1"),
      raw_event(project: @production, device: device, type: Grovs::Events::VIEW, at: Time.utc(2026, 5, 10), session_id: "repeat-may-10"),
      raw_event(project: @production, device: device, type: Grovs::Events::APP_OPEN, at: Time.utc(2026, 5, 31), session_id: "repeat-may-31")
    ])

    assert_billing_parity Date.new(2026, 5, 1), Date.new(2026, 5, 31), expected: 1
    assert_equal 1, ClickhouseReadService.billing_active_visitors_per_month_total(
      billing_project_ids,
      start_date: Date.new(2026, 5, 1),
      end_date: Date.new(2026, 5, 31)
    )
  end

  test "monthly total expands a non-month-aligned start date like Postgres billing" do
    device, = make_device(project: @production, platform: "ios", tag: "partial-start-month")

    ingest_billing_events([
      raw_event(project: @production, device: device, type: Grovs::Events::OPEN, at: Time.utc(2026, 1, 5), session_id: "jan-before-start")
    ])

    start_date = Date.new(2026, 1, 15)
    end_date = Date.new(2026, 1, 31)

    assert_equal 1, @service.compute_maus_per_month_total(@instance, start_date, end_date)
    assert_equal @service.compute_maus_per_month_total(@instance, start_date, end_date),
      ClickhouseReadService.billing_active_visitors_per_month_total(
        billing_project_ids,
        start_date: start_date,
        end_date: end_date
      )
  end

  test "parity check reports match for real Postgres and ClickHouse billing counts" do
    device, = make_device(project: @production, platform: "ios", tag: "parity-monitor")

    ingest_billing_events([
      raw_event(project: @production, device: device, type: Grovs::Events::OPEN, at: Time.utc(2026, 5, 10), session_id: "monitor-open")
    ])

    start_date = Date.new(2026, 5, 1)
    end_date = Date.new(2026, 5, 31)
    result = Billing::ClickhouseParityCheck.compare(
      instance: @instance,
      start_date: start_date,
      end_date: end_date,
      postgres_count: pg_mau_for(start_date, end_date),
      clickhouse_count: ch_mau_for(start_date, end_date)
    )

    assert result.match?
    assert_equal "match", result.status
    assert_equal 1, result.postgres_count
    assert_equal 1, result.clickhouse_count
  end

  test "clickhouse-only and anonymous events do not count as billable active visitors" do
    billable_device, = make_device(project: @production, platform: "ios", tag: "billable")
    custom_only_device, = make_device(project: @production, platform: "ios", tag: "custom-only")
    screen_only_device, = make_device(project: @production, platform: "ios", tag: "screen-only")
    anonymous_device = Device.create!(
      user_agent: "BillingParity/anonymous",
      ip: "192.0.2.201",
      remote_ip: "198.51.100.201",
      platform: "ios",
      vendor: "billing-anonymous-#{SecureRandom.hex(6)}"
    )

    ingest_billing_events([
      raw_event(project: @production, device: billable_device, type: Grovs::Events::OPEN, at: Time.utc(2026, 6, 1), session_id: "billable-open"),
      raw_event(project: @production, device: custom_only_device, type: Grovs::Events::CUSTOM,
                at: Time.utc(2026, 6, 2), session_id: "custom-only", event_name: "billing_custom"),
      raw_event(project: @production, device: screen_only_device, type: Grovs::Events::SCREEN_VIEW,
                at: Time.utc(2026, 6, 3), session_id: "screen-only", event_name: "screen_view"),
      raw_event(project: @production, device: anonymous_device, type: Grovs::Events::OPEN, at: Time.utc(2026, 6, 4), session_id: "anonymous-open")
    ])

    assert_billing_parity Date.new(2026, 6, 1), Date.new(2026, 6, 30), expected: 1
  end

  test "billing windows include first and last day and exclude neighboring days" do
    before_device, = make_device(project: @production, platform: "ios", tag: "before-window")
    first_device, = make_device(project: @production, platform: "ios", tag: "first-day")
    last_device, = make_device(project: @production, platform: "ios", tag: "last-day")
    after_device, = make_device(project: @production, platform: "ios", tag: "after-window")

    ingest_billing_events([
      raw_event(project: @production, device: before_device, type: Grovs::Events::OPEN, at: Time.utc(2026, 4, 30, 23, 59), session_id: "before-window"),
      raw_event(project: @production, device: first_device, type: Grovs::Events::OPEN, at: Time.utc(2026, 5, 1, 0, 0), session_id: "first-day"),
      raw_event(project: @production, device: last_device, type: Grovs::Events::OPEN, at: Time.utc(2026, 5, 31, 23, 59), session_id: "last-day"),
      raw_event(project: @production, device: after_device, type: Grovs::Events::OPEN, at: Time.utc(2026, 6, 1, 0, 0), session_id: "after-window")
    ])

    Rails.cache.write("mau:#{@instance.id}:2026-05", 999, expires_in: 30.days)

    assert_billing_parity Date.new(2026, 5, 1), Date.new(2026, 5, 31), expected: 2
  end

  test "clickhouse billing count is nil when reads are disabled" do
    Rails.application.config.clickhouse_read_enabled = false

    assert_nil ClickhouseReadService.billing_active_visitors(
      billing_project_ids,
      start_date: Date.new(2026, 5, 1),
      end_date: Date.new(2026, 5, 31)
    )
  end

  test "clickhouse billing count is nil when the rollup is unavailable" do
    Clickhouse.with { |conn| conn.execute("DROP TABLE IF EXISTS mv_billing_active_visitors_daily") }
    Clickhouse.with { |conn| conn.execute("DROP TABLE IF EXISTS billing_active_visitors_daily") }

    assert_nil ClickhouseReadService.billing_active_visitors(
      billing_project_ids,
      start_date: Date.new(2026, 5, 1),
      end_date: Date.new(2026, 5, 31)
    )
  ensure
    ClickhouseTestHelper.reset_schema! if ClickhouseTestHelper.available?
  end

  # --- CH-primary open-month billing (§7.3: never over-bill) ---

  test "open month: exact read resolves merges the rollup tail double-counts" do
    device_a, visitor_a = make_device(project: @production, platform: "ios", tag: "merge-a")
    device_b, visitor_b = make_device(project: @production, platform: "web", tag: "merge-b")

    ingest_billing_events([
      raw_event(project: @production, device: device_a, type: Grovs::Events::OPEN, at: Time.utc(2026, 7, 3, 10), session_id: "merge-a-open"),
      raw_event(project: @production, device: device_b, type: Grovs::Events::OPEN, at: Time.utc(2026, 7, 4, 10), session_id: "merge-b-open")
    ])
    # Merge recorded AFTER the rebuild — the rollup partition still holds both raw
    # ids, exactly the between-rebuilds window where the rollup over-reports.
    ClickhouseIdentityMapService.record_merge(@production.id, visitor_a.id, visitor_b.id)

    start_date = Date.new(2026, 7, 1)
    end_date = Date.new(2026, 7, 31)
    rollup = ClickhouseReadService.billing_active_visitors(billing_project_ids, start_date: start_date, end_date: end_date)
    exact = ClickhouseReadService.billing_active_visitors_exact(billing_project_ids, start_date: start_date, end_date: end_date)
    pg = pg_mau_for(start_date, end_date)

    assert_equal 2, rollup, "merge-blind rollup double-counts the merged pair"
    assert_equal 1, exact, "exact read resolves the identity map"
    assert_operator exact, :<=, pg, "billing read must never exceed PG (over-billing guard)"
  end

  test "primary mode current_mau bills the exact merge-aware open-month count" do
    device_a, visitor_a = make_device(project: @production, platform: "ios", tag: "primary-a")
    device_b, visitor_b = make_device(project: @production, platform: "web", tag: "primary-b")

    ingest_billing_events([
      raw_event(project: @production, device: device_a, type: Grovs::Events::OPEN, at: Time.utc(2026, 7, 5, 10), session_id: "primary-a-open"),
      raw_event(project: @production, device: device_b, type: Grovs::Events::VIEW, at: Time.utc(2026, 7, 6, 10), session_id: "primary-b-view")
    ])
    ClickhouseIdentityMapService.record_merge(@production.id, visitor_a.id, visitor_b.id)

    with_primary_mode do
      travel_to Date.new(2026, 7, 15) do
        assert_equal 1, @service.current_mau(@instance)
      end
    end
  end

  test "primary mode bills closed months from the exact deduped read" do
    device, = make_device(project: @production, platform: "ios", tag: "closed-month")

    ingest_billing_events([
      raw_event(project: @production, device: device, type: Grovs::Events::OPEN, at: Time.utc(2026, 5, 10), session_id: "closed-open")
    ])

    with_primary_mode do
      travel_to Date.new(2026, 7, 15) do
        assert_equal 1, @service.compute_mau(@instance, 5, 2026)
      end
    end
  end

  private

  def with_primary_mode
    prev = Rails.application.config.clickhouse_primary
    Rails.application.config.clickhouse_primary = true
    yield
  ensure
    Rails.application.config.clickhouse_primary = prev
  end

  def billing_project_ids
    [@test_project.id, @production.id]
  end

  def make_device(project:, platform:, tag:)
    device = Device.create!(
      user_agent: "BillingParity/#{tag}",
      ip: "192.0.2.#{rand(1..200)}",
      remote_ip: "198.51.100.#{rand(1..200)}",
      platform: platform,
      vendor: "billing-#{tag}-#{SecureRandom.hex(6)}",
      model: "Test Device",
      app_version: "1.0.0",
      build: "1"
    )

    visitor = Visitor.create!(
      project: project,
      device: device,
      web_visitor: platform == "web",
      sdk_identifier: "billing-#{tag}",
      uuid: SecureRandom.uuid
    )

    [device, visitor]
  end

  def raw_event(project:, device:, type:, at:, session_id:, link: nil, event_name: "")
    {
      type: type,
      project_id: project.id,
      device_id: device.id,
      link_id: link&.id,
      data: nil,
      engagement_time: type == Grovs::Events::TIME_SPENT ? 9000 : nil,
      created_at: at.utc.iso8601(3),
      event_name: event_name,
      session_id: session_id,
      tags: []
    }.to_json
  end

  def ingest_billing_events(raw_events)
    job = BatchEventProcessorJob.new
    job.jid = "billing-parity-#{SecureRandom.hex(4)}"
    job.send(:process_batch, raw_events)
    rebuild_ch_breakdowns!
  end

  def pg_mau_for(start_date, end_date)
    @service.send(:compute_mau_for_dates, @instance, start_date, end_date)
  end

  def ch_mau_for(start_date, end_date)
    ClickhouseReadService.billing_active_visitors(
      billing_project_ids,
      start_date: start_date,
      end_date: end_date
    )
  end

  def ch_monthly_total_for(start_date, end_date)
    cursor = start_date.to_date.beginning_of_month
    last = end_date.to_date
    total = 0

    while cursor <= last
      month_end = [cursor.end_of_month, last].min
      total += ch_mau_for(cursor, month_end)
      cursor = (cursor + 1.month).beginning_of_month
    end

    total
  end

  def assert_billing_parity(start_date, end_date, expected:)
    pg_count = pg_mau_for(start_date, end_date)
    ch_count = ch_mau_for(start_date, end_date)

    assert_equal expected, pg_count
    assert_equal pg_count, ch_count
  end

  def flush_billing_redis!
    REDIS.with do |conn|
      conn.del(BatchEventProcessorJob::REDIS_KEY)
      %W[
        #{BatchEventProcessorJob::CH_BATCH_DONE_PREFIX}:*
        events:dedup:*
        events:processing:*
        events:heartbeat:*
        dev_upd_full:*
      ].each do |pattern|
        keys = conn.keys(pattern)
        conn.del(*keys) if keys.any?
      end
    end
  end
end
