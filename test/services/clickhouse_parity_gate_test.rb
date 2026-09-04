# frozen_string_literal: true

require "test_helper"

# CH-gated: the combined GO/NO-GO parity gate (rollup + attribution) a human runs
# before flipping any read flag. PASS on agreement, FAIL on a seeded mismatch, and
# the uncovered dimensions/columns are always surfaced.
class ClickhouseParityGateTest < ActiveSupport::TestCase
  include ClickhouseTestHelper

  fixtures :instances, :projects

  PLATFORM = "ios"

  setup do
    skip_unless_clickhouse!
    Rails.application.config.clickhouse_read_enabled = true
    @project = projects(:one)
    @pid = @project.id
    @date = Date.new(2026, 6, 14)
    REDIS.with { |c| c.del(ClickhouseRollupRebuildService.dirty_key) }
    ActiveRecord::Base.connection.execute("DELETE FROM visitor_daily_statistics WHERE project_id = #{@pid}")
    ActiveRecord::Base.connection.execute("DELETE FROM link_daily_statistics WHERE project_id = #{@pid}")
    ActiveRecord::Base.connection.execute("DELETE FROM daily_project_metrics WHERE project_id = #{@pid}")
  end

  teardown { REDIS.with { |c| c.del(ClickhouseRollupRebuildService.dirty_key) } }

  test "gate PASSes when every rollup metric agrees with PG" do
    seed_pg("visitor_daily_statistics", "visitor_id", 1, views: 3, installs: 1)
    seed_ch("visitor_metrics_daily", visitor_id: 1, views: 3, installs: 1)
    seed_pg("link_daily_statistics", "link_id", 2, views: 4)
    seed_ch("link_metrics_daily", link_id: 2, views: 4)

    gate = Billing::ClickhouseParityCheck.gate(
      project_id: @pid, start_date: @date, end_date: @date,
      rollups: %i[visitor link], attribution_models: %i[]
    )
    assert gate.pass, gate.mismatches.inspect
    assert_empty gate.mismatches
  end

  test "gate FAILs and lists the diverged metric when CH and PG disagree" do
    seed_pg("visitor_daily_statistics", "visitor_id", 1, views: 5)
    seed_ch("visitor_metrics_daily", visitor_id: 1, views: 3)

    gate = Billing::ClickhouseParityCheck.gate(
      project_id: @pid, start_date: @date, end_date: @date,
      rollups: %i[visitor], attribution_models: %i[]
    )
    assert_not gate.pass
    names = gate.mismatches.map { |name, metric, _| [name, metric] }
    assert_includes names, [:rollup_visitor, :views]
  end

  # 37504ea: DPM stores these with 3-day refresh staleness, so grading CH against it
  # measures the refresh window, not CH. They are uncovered, with the reason on record.
  test "project parity reports new_users and first_time_visitors uncovered (stale DPM)" do
    DailyProjectMetric.create!(project_id: @pid, event_date: @date, platform: PLATFORM,
                               new_users: 1, first_time_visitors: 2)

    report = Billing::ClickhouseParityCheck.rollup_parity(
      rollup: :project, project_id: @pid, start_date: @date, end_date: @date
    )

    assert_not report.covered.key?(:new_users), "new_users must NOT be silently covered"
    assert_not report.covered.key?(:first_time_visitors)
    assert report.uncovered[:new_users].present?, "new_users must carry an uncovered reason"
    assert report.uncovered[:first_time_visitors].present?
  end

  test "the default gate covers link_daily, which both link surfaces now serve from" do
    gate = Billing::ClickhouseParityCheck.gate(
      project_id: @pid, start_date: @date, end_date: @date, attribution_models: %i[]
    )

    assert_includes gate.reports.keys, :rollup_link_events
  end

  # link_session_daily cannot be parity-checked, so an empty one must at least block the gate.
  test "gate FAILs when links have activity but the session rollup is empty" do
    seed_link_daily_activity

    gate = Billing::ClickhouseParityCheck.gate(
      project_id: @pid, start_date: @date, end_date: @date, attribution_models: %i[]
    )

    assert_equal 0, gate.session_coverage[:session_links]
    assert_not gate.pass, "an empty session rollup would serve avg_engagement_time 0.0"
  end

  test "gate reports session coverage as n/a when the range has no link activity" do
    gate = Billing::ClickhouseParityCheck.gate(
      project_id: @pid, start_date: @date, end_date: @date, attribution_models: %i[]
    )

    assert_equal :not_applicable, gate.session_coverage
  end

  test "gate always surfaces the explicitly-uncovered columns and dimensions" do
    gate = Billing::ClickhouseParityCheck.gate(
      project_id: @pid, start_date: @date, end_date: @date,
      rollups: %i[project], attribution_models: %i[install]
    )
    # Uncovered project columns (still on PG) and attribution dimensions are namespaced.
    assert gate.uncovered.key?(:"project.revenue"), gate.uncovered.keys.inspect
    # These graduated from uncovered to the per-day serving-reader comparison.
    %i[organic_users link_views referred_users].each do |metric|
      assert gate.reports[:rollup_project].covered.key?(metric)
      assert_not gate.uncovered.key?(:"project.#{metric}")
    end
    assert gate.uncovered.key?(:"attribution.version")
    assert gate.uncovered.key?(:"attribution.country")
    gate.uncovered.each_value { |reason| assert reason.present? }
  end

  test "gate FAILs when visitor_acquisition is missing visitors present in events" do
    insert_ch_events([ch_event(visitor_id: 4001), ch_event(visitor_id: 4002)])

    gate = Billing::ClickhouseParityCheck.gate(
      project_id: @pid, start_date: @date, end_date: @date,
      rollups: %i[visitor], attribution_models: %i[]
    )

    assert_not gate.pass
    assert_equal "fail", gate.status
    assert_not gate.inconclusive
    assert_equal 2, gate.coverage.missing
    assert_not gate.coverage.complete?
  end

  test "gate FAILs on incomplete coverage even when another check is unavailable" do
    insert_ch_events([ch_event(visitor_id: 4501), ch_event(visitor_id: 4502)])

    ClickhouseAttributionReadService.stub(:trusted_recompute_sql, ->(_m) { raise "oracle boom" }) do
      gate = Billing::ClickhouseParityCheck.gate(
        project_id: @pid, start_date: @date, end_date: @date,
        rollups: %i[visitor], attribution_models: %i[install]
      )

      assert gate.unavailable.any?, "the unavailable oracle must still be surfaced"
      assert_equal 2, gate.coverage.missing
      assert_equal "fail", gate.status, "proven-incomplete coverage outranks an unknown"
      assert_not gate.inconclusive
      assert_not gate.pass
    end
  end

  test "gate coverage ignores visitors outside the range, so rebuild lag is not a FAIL" do
    # A visitor whose first event lands after the gate's range has no acquisition row yet.
    insert_ch_events([ch_event(visitor_id: 4601),
                      ch_event(visitor_id: 4602, created_at: (@date + 5).to_time(:utc).strftime("%Y-%m-%d %H:%M:%S.%3N"))])
    ClickhouseRollupRebuildService.rebuild_acquisition(@date.strftime("%Y%m"))
    Clickhouse.with { |c| c.execute("ALTER TABLE visitor_acquisition DELETE WHERE visitor_id = 4602") }

    coverage = Billing::ClickhouseParityCheck.acquisition_coverage(@pid, start_date: @date, end_date: @date)

    assert_equal 0, coverage.missing, "a visitor active only after the range must not count as missing"
    assert coverage.complete?
  end

  test "gate coverage PASSes once every event visitor has an acquisition row" do
    seed_pg("visitor_daily_statistics", "visitor_id", 4101, views: 3)
    seed_ch("visitor_metrics_daily", visitor_id: 4101, views: 3)
    insert_ch_events([ch_event(visitor_id: 4101), ch_event(visitor_id: 4102)])
    ClickhouseRollupRebuildService.rebuild_acquisition(@date.strftime("%Y%m"))

    gate = Billing::ClickhouseParityCheck.gate(
      project_id: @pid, start_date: @date, end_date: @date,
      rollups: %i[visitor], attribution_models: %i[]
    )

    assert_equal 0, gate.coverage.missing
    assert gate.coverage.complete?
    assert gate.pass, gate.mismatches.inspect
  end

  test "gate reports an unavailable oracle as INCONCLUSIVE, not as a mismatch" do
    seed_pg("visitor_daily_statistics", "visitor_id", 1, views: 3)
    seed_ch("visitor_metrics_daily", visitor_id: 1, views: 3)

    ClickhouseAttributionReadService.stub(:trusted_recompute_sql, ->(_m) { raise "oracle boom" }) do
      gate = Billing::ClickhouseParityCheck.gate(
        project_id: @pid, start_date: @date, end_date: @date,
        rollups: %i[visitor], attribution_models: %i[install]
      )

      assert gate.unavailable.any?, "unavailable checks must be surfaced"
      assert_empty gate.mismatches, "an oracle that never ran is not a divergence"
      assert gate.inconclusive
      assert_not gate.pass
      assert_equal "inconclusive", gate.status
    end
  end

  test "gate coverage counts the set difference, not the cardinality difference" do
    insert_ch_events([ch_event(visitor_id: 4201), ch_event(visitor_id: 4202)])
    # Disjoint id with the same COUNT — a cardinality check would pass.
    seed_acquisition(visitor_id: 4201)
    seed_acquisition(visitor_id: 9999)

    coverage = Billing::ClickhouseParityCheck.acquisition_coverage(@pid, start_date: @date, end_date: @date)

    assert_equal 2, coverage.event_visitors
    assert_equal 2, coverage.acquisition_visitors
    assert_equal 1, coverage.missing, "4202 has no acquisition row"
    assert_not coverage.complete?
  end

  # The served read joins post-map visitor_metrics_daily to RAW visitor_acquisition, so a stale
  # pre-merge row does NOT cover the survivor — it resolves to organic. Coverage must say so.
  test "gate coverage FLAGS a survivor whose acquisition row is still keyed pre-merge" do
    insert_ch_events([ch_event(visitor_id: 4302)])
    seed_acquisition(visitor_id: 4301)
    Clickhouse.with do |conn|
      conn.insert("visitor_identity_map", [{ project_id: @pid, from_visitor_id: 4301,
                                             to_visitor_id: 4302, updated_at: ch_ts }])
    end

    coverage = Billing::ClickhouseParityCheck.acquisition_coverage(@pid, start_date: @date, end_date: @date)

    assert_equal 1, coverage.missing, "survivor 4302 has no acquisition row of its own"
    assert_not coverage.complete?
  end

  test "gate stays INCONCLUSIVE when the oracle fails and both attribution sides are empty" do
    seed_pg("visitor_daily_statistics", "visitor_id", 1, views: 3)
    seed_ch("visitor_metrics_daily", visitor_id: 1, views: 3)

    Billing::ClickhouseParityCheck.stub(:attribution_trusted_recompute, ->(*) { nil }) do
      ClickhouseAttributionReadService.stub(:source_breakdown, ->(*, **) { [] }) do
        gate = Billing::ClickhouseParityCheck.gate(
          project_id: @pid, start_date: @date, end_date: @date,
          rollups: %i[visitor], attribution_models: %i[install]
        )

        assert_empty gate.reports[:attribution_install].covered
        assert gate.reports[:attribution_install].unavailable?
        assert gate.unavailable.any?
        assert_not gate.pass, "a silently-failed oracle must not ride along on passing rollups"
        assert gate.inconclusive
      end
    end
  end

  private

  def seed_link_daily_activity
    Clickhouse.with do |conn|
      conn.insert("link_daily", [{
        project_id: @pid, link_id: 991, campaign_id: 0, event_date: @date.to_s,
        event_type: "view", platform: "ios", cnt: 5, total_engagement_time: 0
      }])
    end
  end

  def ch_ts = Time.current.utc.strftime("%Y-%m-%d %H:%M:%S.%3N")

  def seed_acquisition(visitor_id:)
    ts = "toDateTime64('#{@date} 01:00:00.000', 3, 'UTC')"
    src = "toLowCardinality('links')"
    one = "toUInt8(1)"
    Clickhouse.with do |conn|
      conn.execute(<<~SQL)
        INSERT INTO visitor_acquisition SELECT
          toUInt64(#{@pid}), toUInt64(#{visitor_id}),
          argMinIfState(#{src}, (#{ts}, 'seed'), #{one}),
          argMinIfState(#{src}, (#{ts}, 'seed'), #{one}),
          maxIfState(#{one}, #{one}), maxIfState(#{one}, #{one}),
          minIfState(#{ts}, #{one}), minIfState(#{ts}, #{one})
      SQL
    end
  end

  def ch_event(visitor_id:, project_id: nil, created_at: nil)
    { project_id: project_id || @pid, visitor_id: visitor_id, device_id: visitor_id,
      event_type: Grovs::Events::INSTALL, platform: PLATFORM,
      created_at: created_at || (@date.to_time(:utc) + 1.hour).strftime("%Y-%m-%d %H:%M:%S.%3N") }
  end

  def default_metrics
    { views: 0, opens: 0, installs: 0, reinstalls: 0, time_spent: 0,
      reactivations: 0, app_opens: 0, user_referred: 0 }
  end

  def seed_pg(table, key_col, key_val, metrics)
    m = default_metrics.merge(metrics)
    cols = m.keys
    ActiveRecord::Base.connection.execute(
      ActiveRecord::Base.sanitize_sql_array([
        "INSERT INTO #{table} (project_id, #{key_col}, event_date, platform, " \
        "#{cols.join(', ')}, created_at, updated_at) VALUES (?, ?, ?, ?, " \
        "#{(['?'] * cols.size).join(', ')}, NOW(), NOW())",
        @pid, key_val, @date, PLATFORM, *cols.map { |c| m[c] }
      ])
    )
  end

  def seed_ch(table, metrics)
    row = default_metrics.merge(metrics).merge(
      project_id: @pid, event_date: @date.to_s, platform: PLATFORM
    )
    Clickhouse.with { |conn| conn.insert(table, [row]) }
  end
end
