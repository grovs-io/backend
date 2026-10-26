require "test_helper"

class SegmentsPersonMapTest < ActiveSupport::TestCase
  include ClickhouseTestHelper

  PID = 9_101
  T = "2026-09-01 00:00:00.000".freeze

  setup do
    skip_unless_clickhouse!
    @__clickhouse_test_started = true
  end

  def profile(visitor_id, ident) = { project_id: PID, visitor_id: visitor_id, sdk_identifier: ident, first_seen: T, last_seen: T }

  def merge!(from, to)
    Clickhouse.with { |c| c.insert("visitor_identity_map", [{ project_id: PID, from_visitor_id: from, to_visitor_id: to, updated_at: T }]) }
  end

  def identity_row(visitor_id, ident, synced_at)
    { project_id: PID, visitor_id: visitor_id, sdk_identifier: ident, uuid: "", synced_at: synced_at }
  end

  def sync_marker(synced_at)
    identity_row(Analytics::VisitorIdentitySyncService::GENERATION_MARKER_VISITOR_ID, "", synced_at)
  end

  def vmap
    rows = Clickhouse.with { |c| c.select_all("WITH #{Segments::PersonMap.cte(PID)} SELECT raw_id, eff_id, person_key FROM vmap ORDER BY raw_id") }
    rows.to_h { |r| [r["raw_id"].to_i, [r["eff_id"].to_i, r["person_key"]]] }
  end

  test "identified visitors sharing an identifier are one person, anonymous unmerged ones are absent from vmap" do
    insert_ch_user_profiles([profile(1, "ana@x.io"), profile(2, "ana@x.io"), profile(3, "")])
    map = vmap
    assert_equal({ 1 => [1, "i:ana@x.io"], 2 => [2, "i:ana@x.io"] }, map.except(3))
    assert_nil map[3]
  end

  test "identifiers differing only by case or whitespace stay distinct" do
    insert_ch_user_profiles([profile(1, "UserA"), profile(2, "usera"), profile(3, " usera")])
    assert_equal 3, vmap.values.map(&:last).uniq.size
  end

  test "a merged-away visitor takes the survivor's person, even with no profile row" do
    insert_ch_user_profiles([profile(10, ""), profile(11, "bob")])
    merge!(10, 11)
    merge!(12, 11)
    map = vmap
    assert_equal [11, "i:bob"], map[10]
    assert_equal [11, "i:bob"], map[12]
    assert_equal [11, "i:bob"], map[11]
  end

  test "an identifier shared by more than the cap of effective visitors falls back to visitors" do
    insert_ch_user_profiles((1..52).map { |i| profile(i, "guest") })
    assert_equal "v:1", vmap[1].last
    assert_equal 52, vmap.values.map(&:last).uniq.size
  end

  test "merged aliases do not count toward the fan-out cap" do
    insert_ch_user_profiles((1..52).map { |i| profile(i, "carol") })
    (2..52).each { |i| merge!(i, 1) }
    assert_equal ["i:carol"], vmap.values.map(&:last).uniq
  end

  test "an unidentified survivor stays a visitor even when a merged alias had an identifier" do
    insert_ch_user_profiles([profile(1, "alice"), profile(2, "")])
    merge!(1, 2)
    map = vmap
    assert_equal [2, "v:2"], map[1]
    assert_equal [2, "v:2"], map[2]
  end

  test "visitor_identities feeds identity, superseded generations are ignored, and the later-timestamped source wins" do
    old_gen = "2026-08-01 00:00:00.000000000"
    new_gen = "2026-09-01 00:00:00.000000000"
    Clickhouse.with do |c|
      c.insert("visitor_identities", [
        identity_row(20, "old_ident", old_gen),
        identity_row(23, "ghost", old_gen),
        sync_marker(old_gen),
        identity_row(20, "dora", new_gen),
        identity_row(22, "dora2", new_gen),
        identity_row(21, "walt", new_gen),
        identity_row(24, "frank", new_gen),
        sync_marker(new_gen)
      ])
    end
    insert_ch_user_profiles([
      profile(21, "erin").merge(last_seen: "2026-09-02 00:00:00.000"),
      profile(24, "gina").merge(last_seen: "2026-08-15 00:00:00.000")
    ])

    map = vmap
    assert_equal "i:dora", map[20].last
    assert_equal "i:dora2", map[22].last
    assert_equal "i:erin", map[21].last, "a later user_profiles.last_seen must beat an earlier synced identity"
    assert_equal "i:frank", map[24].last, "a later synced identity must beat an earlier user_profiles.last_seen"
    assert_nil map[23], "a visitor that exists only in a superseded generation must not appear in vmap at all"
  end

  test "a later cleared user_profiles identifier overrides an earlier synced visitor_identities one" do
    gen = "2026-09-01 00:00:00.000000000"
    Clickhouse.with do |c|
      c.insert("visitor_identities", [identity_row(30, "old", gen), sync_marker(gen)])
    end
    insert_ch_user_profiles([profile(30, "").merge(last_seen: "2026-09-02 00:00:00.000")])
    assert_equal [30, "v:30"], vmap[30]
  end
end
