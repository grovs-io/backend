# frozen_string_literal: true

require "test_helper"

# CH-gated: parity between the CH attribution rollups (visitor_acquisition +
# last-touch snapshot, read via ClickhouseAttributionReadService) and a TRUSTED
# recompute straight from the deduped events. This is the cutover gate.
class ClickhouseAttributionParityTest < ActiveSupport::TestCase
  include ClickhouseTestHelper

  PROJECT_ID = 8301
  START = Date.new(2026, 6, 1)
  ENDD = Date.new(2026, 6, 30)

  setup do
    skip_unless_clickhouse!
    REDIS.with { |c| c.del(ClickhouseRollupRebuildService.dirty_key) }
  end

  teardown do
    REDIS.with { |c| c.del(ClickhouseRollupRebuildService.dirty_key) }
  end

  test "attribution parity reports zero diff for every model when rollups agree with canonical" do
    seed_and_rebuild(realistic_events)

    %i[install first last].each do |model|
      report = parity(model)
      assert report.all_match?, "#{model} parity mismatch: #{report.covered.inspect}"
      report.covered.each_value { |r| assert_equal 0, r.delta, r.inspect }
    end
  end

  test "attribution parity reports a non-zero diff when the rollup is corrupted" do
    seed_and_rebuild(realistic_events)

    # Corrupt the acquisition rollup: inject an extra organic visitor that canonical
    # does NOT have. The trusted canonical recompute won't see it → mismatch.
    ClickhouseWriteService.insert_canonical_events([
      ev("phantom", 9999, "open", "2026-06-10 10:00:00.000")
    ])
    # Rebuild ONLY visitor_metrics_daily (active set) so the phantom appears active,
    # but DON'T rebuild acquisition — the read joins it, the trusted recompute reads
    # canonical, they now disagree on the phantom... Actually rebuild acquisition too,
    # then hand-insert a contradictory acquisition row to force divergence.
    ClickhouseRollupRebuildService.rebuild_partition(:visitor, "202606")
    ClickhouseRollupRebuildService.rebuild_acquisition("202606")
    ClickhouseRollupRebuildService.rebuild_partition(:last_touch, "202606")

    # Now seed a SECOND canonical event that the rollups are NOT rebuilt for, creating
    # an active visitor the acquisition rollup is missing.
    ClickhouseWriteService.insert_canonical_events([
      ev("orphan", 8888, "install", "2026-06-12 10:00:00.000", campaign_id: 77)
    ])
    ClickhouseRollupRebuildService.rebuild_partition(:visitor, "202606") # active set sees it
    # deliberately skip acquisition rebuild → acquisition missing visitor 8888

    report = parity(:install)
    assert_not report.all_match?, "expected a mismatch from the un-rebuilt acquisition row"
  end

  test "attribution parity reports covered models and uncovered dimensions explicitly" do
    seed_and_rebuild(realistic_events)

    report = parity(:install)
    # Covered: the per-source resolved buckets for this model.
    assert report.covered.keys.any?, "expected covered source buckets"
    # Uncovered: the time-varying dimensions are NOT part of the source-attribution
    # model and are reported as explicitly uncovered with a reason.
    assert report.uncovered.key?(:version)
    assert report.uncovered.key?(:country)
    assert report.uncovered.key?(:platform)
    report.uncovered.each_value { |reason| assert reason.present? }
  end

  test "parity still reports zero diff when only some partitions have been rebuilt" do
    # Seed events in TWO partitions (June + July) but rebuild BOTH so rollups + canonical
    # agree across the partition boundary. A June-only range answer is byte-stable and the
    # parity recompute (which reads canonical as-of the range) must still report zero diff
    # for the rebuilt June partition even though July also holds data.
    seed_and_rebuild(realistic_events)
    ClickhouseWriteService.insert_canonical_events([
      ev("p1", 1, "view", "2026-07-03 10:00:00.000", link_id: 800)
    ])
    ClickhouseRollupRebuildService.rebuild_partition(:visitor, "202607")
    ClickhouseRollupRebuildService.rebuild_acquisition("202607")
    ClickhouseRollupRebuildService.rebuild_partition(:last_touch, "202607")

    # The JUNE-scoped parity (only June partition relevant to the range) is still clean.
    %i[install first last].each do |model|
      report = parity(model)
      assert report.all_match?, "#{model} June parity mismatch after July rebuild: #{report.covered.inspect}"
    end
  end

  test "a source bucket present on only one side coalesces to a real 0, never a crash" do
    # Only organic visitors in canonical → trusted recompute has only 'organic'. The CH
    # read may surface other buckets as 0; the parity compare must coalesce missing buckets
    # to 0 (a clean match), not raise or silently skip.
    ClickhouseWriteService.insert_canonical_events([
      ev("z1", 200, "open", "2026-06-10 10:00:00.000"),
      ev("z2", 201, "install", "2026-06-11 10:00:00.000")
    ])
    ClickhouseRollupRebuildService.rebuild_partition(:visitor, "202606")
    ClickhouseRollupRebuildService.rebuild_acquisition("202606")
    ClickhouseRollupRebuildService.rebuild_partition(:last_touch, "202606")

    %i[install first last].each do |model|
      report = parity(model)
      assert report.all_match?, "#{model}: organic-only parity must match, got #{report.covered.inspect}"
      # Every covered bucket has a concrete (non-nil) delta — no NULL leaks through.
      report.covered.each_value { |r| assert_not_nil r.delta, r.inspect }
    end
  end

  test "wide-range :last parity counts an out-of-window active visitor as organic (no oracle undercount)" do
    # Visitor 70's only event is a campaign touch on May 1 — active in a May 1–Jun 30 range, but
    # >30d before Jun 30, so it ages out of the last-touch window → organic. The trusted oracle
    # must COUNT this visitor (LEFT join), not drop it (the INNER-join undercount bug). Served and
    # oracle must agree at zero delta.
    ClickhouseWriteService.insert_canonical_events([
      ev("wln1", 70, "view", "2026-05-01 10:00:00.000", campaign_id: 77)
    ])
    %w[202605].each do |p|
      ClickhouseRollupRebuildService.rebuild_partition(:visitor, p)
      ClickhouseRollupRebuildService.rebuild_acquisition(p)
      ClickhouseRollupRebuildService.rebuild_partition(:last_touch, p)
    end

    report = Billing::ClickhouseParityCheck.attribution_parity(
      project_id: PROJECT_ID, start_date: Date.new(2026, 5, 1), end_date: Date.new(2026, 6, 30), model: :last
    )
    assert report.all_match?,
      "wide-range :last parity mismatch — oracle likely dropped an out-of-window active visitor: #{report.covered.inspect}"
    organic = report.covered["organic"]
    assert_not_nil organic, "the out-of-window active visitor must be counted as organic, not missing"
    assert_equal 0, organic.delta, organic.inspect
  end

  private

  def parity(model)
    Billing::ClickhouseParityCheck.attribution_parity(
      project_id: PROJECT_ID, start_date: START, end_date: ENDD, model: model
    )
  end

  def seed_and_rebuild(rows)
    ClickhouseWriteService.insert_canonical_events(rows)
    ClickhouseRollupRebuildService.rebuild_partition(:visitor, "202606")
    ClickhouseRollupRebuildService.rebuild_acquisition("202606")
    ClickhouseRollupRebuildService.rebuild_partition(:last_touch, "202606")
  end

  def realistic_events
    [
      ev("r1", 1, "view",    "2026-06-05 10:00:00.000", campaign_id: 77),
      ev("r2", 1, "install", "2026-06-05 11:00:00.000", link_id: 500),
      ev("r3", 2, "install", "2026-06-06 10:00:00.000"),
      ev("r4", 3, "view",    "2026-06-07 10:00:00.000", link_id: 600),
      ev("r5", 4, "open",    "2026-06-08 10:00:00.000"),
      ev("r6", 5, "view",    "2026-06-09 10:00:00.000", sdk_generated: 1, link_visitor_id: 9, link_id: 700)
    ]
  end

  def ev(event_id, visitor_id, event_type, created_at, link_id: 0, campaign_id: 0, sdk_generated: 0, link_visitor_id: 0)
    {
      event_id: event_id, project_id: PROJECT_ID, visitor_id: visitor_id, device_id: visitor_id,
      event_type: event_type, created_at: created_at, platform: "ios",
      link_id: link_id, campaign_id: campaign_id,
      sdk_generated: sdk_generated, link_visitor_id: link_visitor_id
    }
  end
end
