# frozen_string_literal: true

require "test_helper"

# CH-gated: per-visitor attribution (install / first / last) built from the deduped
# canonical store, resolved exactly, and read over a date range with the as-of guarantee.
class ClickhouseAttributionTest < ActiveSupport::TestCase
  include ClickhouseTestHelper

  PROJECT_ID = 8101

  setup do
    skip_unless_clickhouse!
    REDIS.with { |c| c.del(ClickhouseRollupRebuildService.dirty_key) }
  end

  teardown do
    REDIS.with { |c| c.del(ClickhouseRollupRebuildService.dirty_key) }
  end

  # ---- resolver model correctness -----------------------------------------

  test "install model resolves a visitor to the EARLIEST install's source" do
    # Visitor 1: first link-touch is a campaign 'view', then an organic 'install'.
    # install model must report the INSTALL's source (organic), not the first touch.
    seed([
      ev("a1", 1, "view",    "2026-06-10 10:00:00.000", campaign_id: 77),
      ev("a2", 1, "install", "2026-06-10 11:00:00.000")
    ])
    rebuild_all("202606")

    rows = breakdown(model: :install)
    assert_equal({ "organic" => 1 }, rows)
  end

  test "first model resolves a visitor to the EARLIEST link-touch source" do
    seed([
      ev("a1", 1, "view",    "2026-06-10 10:00:00.000", campaign_id: 77),
      ev("a2", 1, "install", "2026-06-10 11:00:00.000")
    ])
    rebuild_all("202606")

    rows = breakdown(model: :first)
    assert_equal({ "campaigns" => 1 }, rows)
  end

  test "no-install visitor falls back to first-touch under the install model" do
    seed([ev("b1", 2, "view", "2026-06-10 10:00:00.000", link_id: 500)])
    rebuild_all("202606")

    assert_equal({ "links" => 1 }, breakdown(model: :install))
  end

  test "no-link no-install visitor resolves to organic under every model" do
    seed([ev("c1", 3, "open", "2026-06-10 10:00:00.000")])
    rebuild_all("202606")

    assert_equal({ "organic" => 1 }, breakdown(model: :install))
    assert_equal({ "organic" => 1 }, breakdown(model: :first))
    assert_equal({ "organic" => 1 }, breakdown(model: :last))
  end

  # ---- tie-break determinism ----------------------------------------------

  test "two installs at the same instant tie-break deterministically by event_id" do
    # Same created_at, two different sources; argMin tie-breaks on event_id ('z..' > 'a..').
    rows1 = nil
    rows2 = nil
    seed([
      ev("aaa", 4, "install", "2026-06-10 10:00:00.000", campaign_id: 77),
      ev("zzz", 4, "install", "2026-06-10 10:00:00.000", link_id: 500)
    ])
    rebuild_all("202606")
    rows1 = install_source_for(4)

    truncate_clickhouse_tables
    # Re-seed in the opposite insertion order; the resolved source must be identical.
    seed([
      ev("zzz", 4, "install", "2026-06-10 10:00:00.000", link_id: 500),
      ev("aaa", 4, "install", "2026-06-10 10:00:00.000", campaign_id: 77)
    ])
    rebuild_all("202606")
    rows2 = install_source_for(4)

    assert_equal "campaigns", rows1, "earliest (created_at,event_id) is event_id 'aaa' → campaigns"
    assert_equal rows1, rows2, "tie-break must be insertion-order independent"
  end

  # ---- dup stability ------------------------------------------------------

  test "a duplicate canonical row does not change attribution" do
    events = [
      ev("d1", 5, "view",    "2026-06-10 10:00:00.000", campaign_id: 77),
      ev("d2", 5, "install", "2026-06-10 11:00:00.000")
    ]
    seed(events)
    seed([events.first]) # re-deliver same event_id
    rebuild_all("202606")

    assert_equal({ "organic" => 1 }, breakdown(model: :install))
    assert_equal({ "campaigns" => 1 }, breakdown(model: :first))
  end

  # ---- as-of stability (headline) -----------------------------------------

  test "a past range's last-touch answer is UNCHANGED after new events arrive" do
    # June: visitor 6's last link-touch is a campaign.
    seed([ev("e1", 6, "view", "2026-06-10 10:00:00.000", campaign_id: 77)])
    rebuild_all("202606")
    june = breakdown(model: :last, start_date: "2026-06-01", end_date: "2026-06-30")
    assert_equal({ "campaigns" => 1 }, june)

    # July: a NEW link-touch (links) arrives. The JUNE range answer must NOT change.
    seed([ev("e2", 6, "view", "2026-07-05 10:00:00.000", link_id: 500)])
    rebuild_all("202606")
    rebuild_all("202607")

    june_again = breakdown(model: :last, start_date: "2026-06-01", end_date: "2026-06-30")
    assert_equal({ "campaigns" => 1 }, june_again, "past range last-touch must be stable (as-of)")

    # The wider range sees the newer last-touch.
    wide = breakdown(model: :last, start_date: "2026-06-01", end_date: "2026-07-31")
    assert_equal({ "links" => 1 }, wide)
  end

  test "a link-touch older than the last-touch window ages out to organic under :last" do
    # Visitor 90: a campaign link-touch in MAY (>30d before the June-30 range end) plus a
    # plain June open that keeps them active in range. The May touch is outside the window,
    # so last-touch sees no in-window link → organic. Unbounded, it would be campaigns.
    seed([
      ev("w1", 90, "view", "2026-05-20 10:00:00.000", campaign_id: 77),
      ev("w2", 90, "open", "2026-06-15 10:00:00.000")
    ])
    rebuild_all("202605")
    rebuild_all("202606")

    assert_equal({ "organic" => 1 },
                 breakdown(model: :last, start_date: "2026-06-01", end_date: "2026-06-30"),
                 "a touch older than LAST_TOUCH_WINDOW_DAYS before the range end must age out to organic")
  end

  test "last-touch window boundary: a touch at exactly end_date-30 counts, end_date-31 ages out" do
    # end_date 2026-06-30 → window start = 2026-05-31 (event_date >= end_date - 30). Guards the
    # off-by-one: visitor 195's touch is exactly on the boundary (in), 196's is one day earlier (out).
    seed([
      ev("bd_in", 195, "view", "2026-05-31 10:00:00.000", campaign_id: 77),
      ev("bd_out", 196, "view", "2026-05-30 10:00:00.000", campaign_id: 77)
    ])
    rebuild_all("202605")

    assert_equal({ "campaigns" => 1, "organic" => 1 },
                 breakdown(model: :last, start_date: "2026-05-01", end_date: "2026-06-30"),
                 "195 (touch at end_date-30) = campaigns; 196 (end_date-31) aged out = organic")
  end

  test "resolved_source_for(:last) binds end_date (as-of today) and returns the in-window last touch" do
    # Regression: single_visitor_query(:last) left {end_date} unbound → the query raised and was
    # rescued to nil. It now defaults end_date to today, so a recent touch resolves correctly.
    recent = Date.current - 5
    seed([ev("rs1", 95, "view", "#{recent} 10:00:00.000", link_id: 500)])
    [recent, Date.current].map { |d| d.strftime("%Y%m") }.uniq.each { |p| rebuild_all(p) }

    assert_equal "links", ClickhouseAttributionReadService.resolved_source_for(PROJECT_ID, 95, model: :last),
                 "single-visitor :last must resolve (was nil due to an unbound end_date placeholder)"
  end

  test "date-ranged breakdown sums to uniqExact of distinct active visitors in the range" do
    seed([
      ev("f1", 10, "install", "2026-06-10 10:00:00.000", campaign_id: 77),
      ev("f2", 11, "install", "2026-06-10 10:00:00.000", link_id: 500),
      ev("f3", 12, "open",    "2026-06-10 10:00:00.000")
    ])
    rebuild_all("202606")

    rows = breakdown(model: :install)
    assert_equal 3, rows.values.sum
    assert_equal({ "campaigns" => 1, "links" => 1, "organic" => 1 }, rows)
  end

  # ---- merged visitor (Phase 4) -------------------------------------------

  test "a merged visitor attributes under the survivor with the survivor's earliest install source" do
    # Visitor 20 (survivor) installs organically at 09:00. Visitor 21 (merged into 20)
    # installs via campaign at 10:00. After merge, the survivor's EARLIEST install (09:00,
    # organic) must win — the merged visitor's later campaign install must not override it.
    seed([
      ev("g1", 20, "install", "2026-06-10 09:00:00.000"),
      ev("g2", 21, "install", "2026-06-10 10:00:00.000", campaign_id: 77)
    ])
    ClickhouseIdentityMapService.record_merge(PROJECT_ID, 21, 20)
    rebuild_all("202606")

    rows = breakdown(model: :install)
    assert_equal({ "organic" => 1 }, rows, "single survivor, earliest install source preserved")
    assert_equal "organic", install_source_for(20)
  end

  test "rebuild_all_dirty builds visitor_acquisition for the watermark window" do
    seed([ev("j1", 50, "install", "2026-06-10 10:00:00.000", campaign_id: 77)])
    ClickhouseRollupRebuildService.mark_dirty(Date.new(2026, 6, 10))

    travel_to Time.utc(2026, 6, 26) do
      ClickhouseRollupRebuildService.rebuild_all_dirty(watermark_months: 0)
    end

    assert_equal "campaigns", install_source_for(50)
    assert_empty ClickhouseRollupRebuildService.dirty_partitions
  end

  # ---- time-varying dimension exactness -----------------------------------

  test "version/country/platform are exact per-day uniqExact and time-varying" do
    # Visitor 30 active on two days under DIFFERENT app_versions; counted under BOTH
    # over the range (their own time-varying definition), not folded into one.
    seed([
      ev("h1", 30, "open", "2026-06-10 10:00:00.000").merge(app_version: "1.0", country: "US"),
      ev("h2", 30, "open", "2026-06-11 10:00:00.000").merge(app_version: "2.0", country: "US"),
      ev("h3", 31, "open", "2026-06-10 10:00:00.000").merge(app_version: "1.0", country: "DE")
    ])
    ClickhouseRollupRebuildService.rebuild_partition(:dimension, "202606")

    versions = dimension(:version)
    assert_equal({ "1.0" => 2, "2.0" => 1 }, versions)

    countries = dimension(:country)
    assert_equal({ "US" => 1, "DE" => 1 }, countries)

    platforms = dimension(:platform)
    assert_equal({ "ios" => 2 }, platforms)
  end

  test "duplicate canonical rows do not inflate the exact dimension counts" do
    rows = [ev("i1", 40, "open", "2026-06-10 10:00:00.000").merge(app_version: "9.9")]
    seed(rows)
    seed(rows) # same event_id re-delivered
    ClickhouseRollupRebuildService.rebuild_partition(:dimension, "202606")

    assert_equal({ "9.9" => 1 }, dimension(:version))
  end

  # ---- uniqExact memory guard ---------------------------------------------

  test "every uniqExact read carries explicit memory guards" do
    guards = ClickhouseAttributionReadService::MEMORY_GUARDS
    assert_includes guards, "max_memory_usage"
    assert_includes guards, "max_bytes_before_external_group_by"
  end

  test "breakdown stays correct at higher visitor cardinality" do
    rows = (1..200).map do |v|
      src = v.even? ? { campaign_id: 77 } : {}
      ev("k#{v}", 1000 + v, "install", "2026-06-10 10:00:00.000", **src)
    end
    seed(rows)
    rebuild_all("202606")

    result = breakdown(model: :install)
    assert_equal 100, result["campaigns"]
    assert_equal 100, result["organic"]
    assert_equal 200, result.values.sum
  end

  # ---- has_link includes campaigns / sdk-referrals even with link_id=0 -----

  test "a campaign view with link_id=0 counts as a first-touch link under :first" do
    # Visitor's ONLY event is a campaign 'view' carrying campaign_id but link_id=0.
    # Per Analytics::SourceTaxonomy, that IS an attributable touch → 'campaigns', NOT organic.
    seed([ev("la1", 60, "view", "2026-06-10 10:00:00.000", campaign_id: 77, link_id: 0)])
    rebuild_all("202606")

    assert_equal({ "campaigns" => 1 }, breakdown(model: :first),
                 "campaign with link_id=0 must attribute to campaigns, not organic")
    # install model with no install falls back to first-touch → also campaigns.
    assert_equal({ "campaigns" => 1 }, breakdown(model: :install))
    # The single-visitor resolver reflects has_link via the first-touch fallback.
    assert_equal "campaigns", install_source_for(60)
  end

  test "an sdk-generated referral with link_id=0 counts as a first-touch link under :first" do
    seed([ev("lb1", 61, "view", "2026-06-10 10:00:00.000",
             sdk_generated: 1, link_visitor_id: 9, link_id: 0)])
    rebuild_all("202606")

    assert_equal({ "referrals" => 1 }, breakdown(model: :first),
                 "sdk referral with link_id=0 must attribute to referrals, not organic")
    assert_equal({ "referrals" => 1 }, breakdown(model: :install))
  end

  # ---- merged visitor under :first AND :last -------------------------------

  test "a merged survivor keeps its EARLIEST first-touch source, not the merged visitor's later one" do
    # Survivor 70 first-touches via links at 09:00. Merged visitor 71 first-touches via
    # campaign at 10:00. After merge the survivor's EARLIEST touch (09:00 links) must win.
    seed([
      ev("m1", 70, "view", "2026-06-10 09:00:00.000", link_id: 500),
      ev("m2", 71, "view", "2026-06-10 10:00:00.000", campaign_id: 77)
    ])
    ClickhouseIdentityMapService.record_merge(PROJECT_ID, 71, 70)
    rebuild_all("202606")

    assert_equal({ "links" => 1 }, breakdown(model: :first),
                 "earliest first-touch (links) survives the merge")
  end

  test "a merged visitor's last-touch under :last reflects the latest touch across both visitors" do
    # Survivor 72 last-touches via links at 09:00. Merged 73 last-touches via campaign at
    # 11:00. The merged set's LATEST touch (11:00 campaign) is the last-touch answer.
    seed([
      ev("m3", 72, "view", "2026-06-10 09:00:00.000", link_id: 500),
      ev("m4", 73, "view", "2026-06-10 11:00:00.000", campaign_id: 77)
    ])
    ClickhouseIdentityMapService.record_merge(PROJECT_ID, 73, 72)
    rebuild_all("202606")

    assert_equal({ "campaigns" => 1 }, breakdown(model: :last),
                 "latest touch across the merged set wins under :last")
  end

  # ---- as-of semantics, made precise --------------------------------------

  test "FUTURE-dated events never change a past range answer for ALL three models" do
    # Establish concrete June answers across all models.
    seed([
      ev("af1", 80, "install", "2026-06-10 10:00:00.000", campaign_id: 77),
      ev("af2", 80, "view",    "2026-06-12 10:00:00.000", link_id: 500)
    ])
    rebuild_all("202606")

    before = {
      install: breakdown(model: :install, start_date: "2026-06-01", end_date: "2026-06-30"),
      first: breakdown(model: :first, start_date: "2026-06-01", end_date: "2026-06-30"),
      last: breakdown(model: :last, start_date: "2026-06-01", end_date: "2026-06-30")
    }
    assert_equal({ "campaigns" => 1 }, before[:install])
    assert_equal({ "campaigns" => 1 }, before[:first])
    assert_equal({ "links" => 1 }, before[:last])

    # Add canonical events DATED AFTER the June range, rebuild affected partitions.
    seed([
      ev("af3", 80, "install", "2026-07-05 10:00:00.000", link_id: 600),
      ev("af4", 80, "view",    "2026-07-06 10:00:00.000", sdk_generated: 1, link_visitor_id: 3)
    ])
    rebuild_all("202606")
    rebuild_all("202607")

    %i[install first last].each do |model|
      again = breakdown(model: model, start_date: "2026-06-01", end_date: "2026-06-30")
      assert_equal before[model], again,
                   "#{model}: future-dated events must not change the past June range"
    end
  end

  test "an event DATED INSIDE a past range DOES change that range's last-touch (correct as-of)" do
    # June 10: last-touch is a campaign (single touch).
    seed([ev("ai1", 90, "view", "2026-06-10 10:00:00.000", campaign_id: 77)])
    rebuild_all("202606")
    assert_equal({ "campaigns" => 1 },
                 breakdown(model: :last, start_date: "2026-06-01", end_date: "2026-06-30"))

    # A late delivery DATED June 20 (inside the range, crossing a day boundary) arrives.
    # The as-of-June-30 last-touch must now reflect the LATER in-range touch (links).
    seed([ev("ai2", 90, "view", "2026-06-20 10:00:00.000", link_id: 500)])
    rebuild_all("202606")

    assert_equal({ "links" => 1 },
                 breakdown(model: :last, start_date: "2026-06-01", end_date: "2026-06-30"),
                 "a late event dated inside the range legitimately changes last-touch")
  end

  # ---- last-touch organic fallback ----------------------------------------

  test "a visitor with no link touch resolves to organic under :last" do
    seed([
      ev("lt1", 100, "install", "2026-06-10 10:00:00.000"),
      ev("lt2", 100, "open",    "2026-06-11 10:00:00.000")
    ])
    rebuild_all("202606")

    assert_equal({ "organic" => 1 }, breakdown(model: :last))
  end

  # ---- tie-break across a day boundary ------------------------------------

  test "first/last selection is correct across days and ties break by event_id" do
    # Two touches with EQUAL created_at on June 10 (tie → event_id 'tb_a' < 'tb_z' → campaigns);
    # a later distinct touch on June 12 (links). first → June-10 campaign; last → June-12 link.
    seed([
      ev("tb_z", 110, "view", "2026-06-10 10:00:00.000", link_id: 500),
      ev("tb_a", 110, "view", "2026-06-10 10:00:00.000", campaign_id: 77),
      ev("tb_l", 110, "view", "2026-06-12 10:00:00.000", link_id: 600)
    ])
    rebuild_all("202606")

    assert_equal({ "campaigns" => 1 }, breakdown(model: :first),
                 "earliest touch: tie on June 10 breaks to event_id 'tb_a' → campaigns")
    assert_equal({ "links" => 1 }, breakdown(model: :last),
                 "latest touch is the distinct June 12 link")
  end

  # ---- merged visitor dimension cardinality -------------------------------

  test "a merged visitor is counted once under the survivor in the per-day dimension" do
    # Survivor 120 and merged 121 both active June 10 under app_version 5.5. After merge they
    # are ONE effective visitor → uniqExact must count 1, not 2.
    seed([
      ev("dm1", 120, "open", "2026-06-10 10:00:00.000").merge(app_version: "5.5"),
      ev("dm2", 121, "open", "2026-06-10 10:00:00.000").merge(app_version: "5.5")
    ])
    ClickhouseIdentityMapService.record_merge(PROJECT_ID, 121, 120)
    ClickhouseRollupRebuildService.rebuild_partition(:dimension, "202606")

    assert_equal({ "5.5" => 1 }, dimension(:version),
                 "merged visitor counts once under the survivor")
  end

  private

  def dimension(dim)
    ClickhouseAttributionReadService.dimension_breakdown(
      PROJECT_ID, start_date: "2026-06-01", end_date: "2026-06-30", dimension: dim
    ).to_h { |r| [r["value"], r["visitors"].to_i] }
  end

  def seed(rows)
    ClickhouseWriteService.insert_canonical_events(rows)
  end

  def rebuild_all(partition)
    ClickhouseRollupRebuildService.rebuild_partition(:visitor, partition)
    ClickhouseRollupRebuildService.rebuild_acquisition(partition)
    ClickhouseRollupRebuildService.rebuild_partition(:last_touch, partition)
  end

  def breakdown(model:, start_date: "2026-06-01", end_date: "2026-06-30")
    ClickhouseAttributionReadService.source_breakdown(
      PROJECT_ID, start_date: start_date, end_date: end_date, model: model
    ).to_h { |r| [r["source"], r["visitors"].to_i] }
  end

  def install_source_for(visitor_id)
    ClickhouseAttributionReadService.resolved_source_for(PROJECT_ID, visitor_id, model: :install)
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
