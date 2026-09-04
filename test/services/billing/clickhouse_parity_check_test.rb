# frozen_string_literal: true

require "test_helper"

class Billing::ClickhouseParityCheckTest < ActiveSupport::TestCase
  test "reports match with zero delta" do
    result = Billing::ClickhouseParityCheck.compare(
      instance: parity_instance,
      start_date: Date.new(2026, 5, 1),
      end_date: Date.new(2026, 5, 31),
      postgres_count: 10,
      clickhouse_count: 10
    )

    assert_equal true, result.match?
    assert_equal 0, result.delta
    assert_equal 0.0, result.percent_delta
    assert_equal "match", result.status
  end

  test "reports mismatch with absolute and percent delta" do
    result = Billing::ClickhouseParityCheck.compare(
      instance: parity_instance,
      start_date: Date.new(2026, 5, 1),
      end_date: Date.new(2026, 5, 31),
      postgres_count: 100,
      clickhouse_count: 98
    )

    assert_equal false, result.match?
    assert_equal(-2, result.delta)
    assert_in_delta(-2.0, result.percent_delta, 0.001)
    assert_equal "mismatch", result.status
  end

  test "nil clickhouse count is not a match" do
    result = Billing::ClickhouseParityCheck.compare(
      instance: parity_instance,
      start_date: Date.new(2026, 5, 1),
      end_date: Date.new(2026, 5, 31),
      postgres_count: 100,
      clickhouse_count: nil
    )

    assert_equal false, result.match?
    assert_nil result.delta
    assert_nil result.percent_delta
    assert_equal "clickhouse_unavailable", result.status
  end

  test "zero postgres count only matches zero clickhouse count" do
    zero_result = Billing::ClickhouseParityCheck.compare(
      instance: parity_instance,
      start_date: Date.new(2026, 5, 1),
      end_date: Date.new(2026, 5, 31),
      postgres_count: 0,
      clickhouse_count: 0
    )
    nonzero_result = Billing::ClickhouseParityCheck.compare(
      instance: parity_instance,
      start_date: Date.new(2026, 5, 1),
      end_date: Date.new(2026, 5, 31),
      postgres_count: 0,
      clickhouse_count: 1
    )

    assert_equal true, zero_result.match?
    assert_equal 0.0, zero_result.percent_delta
    assert_equal false, nonzero_result.match?
    assert_nil nonzero_result.percent_delta
    assert_equal "clickhouse_only", nonzero_result.status
    assert_nothing_raised { JSON.generate(nonzero_result.to_h) }
  end

  # Redelivery-tolerant band (app_opens and time_spent): CH is expected below PG because the
  # content-hash event_id collapses client retransmits PG counted individually. This is
  # an ACCEPTED, separately-reported delta — NOT a match.
  test "tolerant metric below PG within the band is an accepted_redelivery_delta, not a match" do
    r = compare(postgres: 100, clickhouse: 90, tolerant: true) # 10% shortfall <= 15% cap
    assert_equal "accepted_redelivery_delta", r.status
    assert_not r.match?, "an accepted delta must NOT read as strict parity"
    assert r.accepted_redelivery_delta?
    assert r.passing?, "accepted delta is non-blocking for the gate"
    assert_equal(-10, r.delta)
  end

  test "tolerant metric below PG beyond the band still fails" do
    r = compare(postgres: 100, clickhouse: 80, tolerant: true) # 20% shortfall > 15% cap
    assert_equal "mismatch", r.status
    assert_not r.passing?, "a shortfall beyond the band is real data loss — must fail"
  end

  test "tolerant metric ABOVE PG fails (CH must never invent events)" do
    r = compare(postgres: 100, clickhouse: 101, tolerant: true)
    assert_equal "mismatch", r.status
    assert_not r.passing?
  end

  test "tolerant metric with exact match is a plain match, not an accepted delta" do
    r = compare(postgres: 100, clickhouse: 100, tolerant: true)
    assert_equal "match", r.status
    assert r.match?
    assert_not r.accepted_redelivery_delta?
  end

  test "non-tolerant metric stays strict — one short is a mismatch" do
    r = compare(postgres: 100, clickhouse: 99, tolerant: false)
    assert_equal "mismatch", r.status
    assert_not r.passing?
  end

  private

  def compare(postgres:, clickhouse:, tolerant:)
    Billing::ClickhouseParityCheck.send(
      :compare_counts, 1, Date.new(2026, 5, 1), Date.new(2026, 5, 31),
      postgres, clickhouse, tolerant: tolerant
    )
  end

  def parity_instance
    Struct.new(:id).new(123)
  end
end

# CH-gated: the Phase 6 GO/NO-GO gate over the project/link/visitor count rollups.
class Billing::ClickhouseParityGateTest < ActiveSupport::TestCase
  include ClickhouseTestHelper

  fixtures :instances, :projects, :devices, :visitors, :domains, :redirect_configs

  ROLLUPS = %i[project link visitor].freeze

  setup do
    skip_unless_clickhouse!
    @project = projects(:one)
    @pid = @project.id
    @date = Date.new(2026, 6, 18)
    Rails.application.config.clickhouse_read_enabled = true
    DailyProjectMetric.where(project_id: @pid).delete_all
    LinkDailyStatistic.where(project_id: @pid).delete_all
    VisitorDailyStatistic.where(project_id: @pid).delete_all
    truncate_clickhouse_tables
    @link = Link.create!(domain: domains(:one), redirect_config: redirect_configs(:one),
                         path: "gate-link", title: "Gate", generated_from_platform: "ios",
                         active: true, sdk_generated: false, data: "[]")
    @visitor = visitors(:ios_visitor)
  end

  teardown { Rails.application.config.clickhouse_read_enabled = false }

  test "gate is INCONCLUSIVE (not PASS) when both sides have zero rows" do
    gate = Billing::ClickhouseParityCheck.gate(
      project_id: @pid, start_date: @date, end_date: @date,
      rollups: ROLLUPS, attribution_models: %i[]
    )

    assert gate.inconclusive, "an empty comparison must be flagged inconclusive"
    assert_not gate.pass, "an empty comparison must NOT be a confident PASS"
    assert_equal "inconclusive", gate.status
  end

  test "gate FAILs when a covered metric diverges, captures the mismatch, and lists uncovered" do
    seed_pg(views: 100)
    seed_ch(views: 99) # CH one short of PG → divergence on every rollup's views

    gate = Billing::ClickhouseParityCheck.gate(
      project_id: @pid, start_date: @date, end_date: @date,
      rollups: ROLLUPS, attribution_models: %i[]
    )

    assert_not gate.pass, "a divergence must FAIL the gate"
    assert_not gate.inconclusive, "there IS data, so it is not inconclusive"
    assert_equal "fail", gate.status

    views_mismatches = gate.mismatches.select { |_name, metric, _r| metric == :views }
    assert views_mismatches.any?, "views divergence must appear in mismatches"
    views_mismatches.each { |_name, _metric, r| assert_equal(-1, r.delta) }

    # The gate covers all three rollups...
    assert_equal %i[rollup_project rollup_link rollup_visitor].sort, gate.reports.keys.sort
    # ...and the always-present uncovered list names intentionally-uncovered PG columns.
    assert gate.uncovered.any?, "uncovered must be non-empty"
    assert_includes gate.uncovered.keys, :"project.revenue"
    assert_includes gate.uncovered.keys, :"link.revenue"
  end

  test "gate PASSes when every covered metric matches across all rollups" do
    seed_pg(views: 100)
    seed_ch(views: 100)

    gate = Billing::ClickhouseParityCheck.gate(
      project_id: @pid, start_date: @date, end_date: @date,
      rollups: ROLLUPS, attribution_models: %i[]
    )

    assert gate.pass, "matching data must PASS: #{gate.mismatches.inspect}"
    assert_not gate.inconclusive
    assert_equal "pass", gate.status
  end

  # parity_gate rake exits non-zero on a FAILED gate. Asserted at the service level:
  # `abort` is driven by `gate.pass` being false (see clickhouse.rake#parity_gate).
  test "a failed gate drives a non-zero rake exit" do
    seed_pg(views: 100)
    seed_ch(views: 99)

    gate = Billing::ClickhouseParityCheck.gate(
      project_id: @pid, start_date: @date, end_date: @date,
      rollups: ROLLUPS, attribution_models: %i[]
    )

    # The rake task aborts (exit 1) unless gate.pass is truthy and gate.inconclusive false.
    should_abort = gate.inconclusive || !gate.pass
    assert should_abort, "rake parity_gate must abort (non-zero) on a failed gate"
  end

  test "gate PASSes app_opens within the band but reports it as an accepted delta, not a match" do
    seed_pg(views: 100, app_opens: 100)
    seed_ch(views: 100, app_opens: 90) # 10% shortfall <= 15% cap: retransmit dedup, expected

    gate = Billing::ClickhouseParityCheck.gate(
      project_id: @pid, start_date: @date, end_date: @date,
      rollups: ROLLUPS, attribution_models: %i[]
    )

    assert gate.pass, "within-band app_opens shortfall must PASS: #{gate.mismatches.inspect}"
    assert_equal "pass", gate.status
    # ...but it is surfaced LOUDLY as an accepted delta, never as a silent ordinary match.
    accepted_metrics = gate.accepted_deltas.map { |_name, metric, _r| metric }
    assert_includes accepted_metrics, :app_opens
    assert_empty gate.mismatches, "an accepted delta must not be counted as a mismatch"
  end

  test "gate FAILs when app_opens falls below PG beyond the redelivery band" do
    seed_pg(views: 100, app_opens: 100)
    seed_ch(views: 100, app_opens: 70) # 30% shortfall > 15% cap: real data loss, not dedup

    gate = Billing::ClickhouseParityCheck.gate(
      project_id: @pid, start_date: @date, end_date: @date,
      rollups: ROLLUPS, attribution_models: %i[]
    )

    assert_not gate.pass, "an app_opens shortfall beyond the band must FAIL"
    assert gate.mismatches.any? { |_name, metric, _r| metric == :app_opens }
  end

  private

  def seed_pg(views:, app_opens: 0)
    # link_views mirrors the LDS views below, the way the metrics generator derives it.
    DailyProjectMetric.create!(project_id: @pid, event_date: @date, platform: "ios",
                               views: views, app_opens: app_opens, link_views: views)
    LinkDailyStatistic.create!(project_id: @pid, link_id: @link.id, event_date: @date,
                               platform: "ios", views: views, app_opens: app_opens)
    VisitorDailyStatistic.create!(project_id: @pid, visitor_id: @visitor.id, event_date: @date,
                                  platform: "ios", views: views, app_opens: app_opens)
  end

  def seed_ch(views:, app_opens: 0)
    base = { project_id: @pid, event_date: @date.to_s, platform: "ios", views: views }
    Clickhouse.with do |conn|
      conn.insert("project_metrics_daily",
                  [base.merge(opens: 0, installs: 0, reinstalls: 0, app_opens: app_opens,
                              unique_visitors: 0, unique_devices: 0)])
      conn.insert("link_metrics_daily",
                  [base.merge(link_id: @link.id, opens: 0, installs: 0, reinstalls: 0,
                              time_spent: 0, reactivations: 0, app_opens: app_opens, user_referred: 0)])
      conn.insert("visitor_metrics_daily",
                  [base.merge(visitor_id: @visitor.id, opens: 0, installs: 0, reinstalls: 0,
                              time_spent: 0, reactivations: 0, app_opens: app_opens, user_referred: 0,
                              inviter_id: 0)])
    end
  end
end
