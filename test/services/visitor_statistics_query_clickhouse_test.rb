# frozen_string_literal: true

require "test_helper"

# CH values differ from the PG fixture rows (130/1300, 30/300) so each number's source is provable.
class VisitorStatisticsQueryClickhouseTest < ActiveSupport::TestCase
  include ClickhouseTestHelper

  fixtures :projects, :instances, :devices, :visitors, :visitor_daily_statistics

  setup do
    skip_unless_clickhouse!
    truncate_clickhouse_tables
    @project = projects(:one)
    @ios_visitor = visitors(:ios_visitor)
    @android_visitor = visitors(:android_visitor)

    @original_read = Rails.application.config.clickhouse_read_enabled
    @original_rollups = Rails.application.config.clickhouse_analytics_rollups_read_enabled
    Rails.application.config.clickhouse_read_enabled = true
    Rails.application.config.clickhouse_analytics_rollups_read_enabled = true
    # Pin the ledger flag so a CI env with REVENUE_READS_FROM_LEDGER=true can't flip legacy assertions.
    @original_ledger = Rails.application.config.revenue_reads_from_ledger
    Rails.application.config.revenue_reads_from_ledger = false

    insert_visitor_metrics([
      row(@ios_visitor.id, "2026-03-01", "ios",
          views: 900, opens: 40, installs: 13, reinstalls: 3, time_spent: 8000,
          reactivations: 1, app_opens: 30, user_referred: 6),
      row(@android_visitor.id, "2026-03-01", "android", views: 5, opens: 2, installs: 1)
    ])
    seed_profiles(@ios_visitor, @android_visitor)
  end

  teardown do
    Rails.application.config.clickhouse_read_enabled = @original_read
    Rails.application.config.clickhouse_analytics_rollups_read_enabled = @original_rollups
    Rails.application.config.revenue_reads_from_ledger = @original_ledger
  end

  test "metric sort orders by CH totals with metadata and revenue from PG" do
    result = query(sort_by: "views", ascendent: false).call

    assert_equal [@ios_visitor.id, @android_visitor.id], result[:visitors].map { |v| v["id"] }
    top = result[:visitors].first
    assert_equal 900, top["total_views"], "views must come from CH (PG says 130)"
    assert_equal 13, top["total_installs"]
    assert_equal 8000, top["total_time_spent"]
    assert_equal 1300, top["total_revenue"], "revenue still sourced from PG"
    assert_equal "ios", top["platform"]
    assert_equal @ios_visitor.uuid, top["uuid"]
    assert_equal 2, result[:meta][:total_entries]
  end

  test "default sort orders by visitor_id desc (created_at proxy)" do
    ids = query.call[:visitors].map { |v| v["id"] }

    assert_equal [@ios_visitor.id, @android_visitor.id].sort.reverse, ids
  end

  test "created_at asc sort maps to visitor_id asc" do
    ids = query(sort_by: "created_at", ascendent: true).call[:visitors].map { |v| v["id"] }

    assert_equal [@ios_visitor.id, @android_visitor.id].sort, ids
  end

  test "term filter resolves in PG and scopes the CH population" do
    result = query(term: "user_ios").call

    assert_equal [@ios_visitor.id], result[:visitors].map { |v| v["id"] }
    assert_equal 1, result[:meta][:total_entries]
    assert_equal 900, result[:visitors].first["total_views"]
  end

  test "platform filter scopes population by normalized event platform" do
    result = query(platform: "android").call

    assert_equal [@android_visitor.id], result[:visitors].map { |v| v["id"] }
    assert_equal 1, result[:meta][:total_entries]
    assert_equal 5, result[:visitors].first["total_views"]
  end

  test "platform filter also scopes PG revenue, not just CH counts" do
    # ios_visitor gains android activity: CH row + PG revenue row on android.
    insert_visitor_metrics([row(@ios_visitor.id, "2026-03-01", "android", views: 2)])
    VisitorDailyStatistic.create!(visitor: @ios_visitor, project_id: @project.id,
                                  event_date: "2026-03-01", platform: "android", revenue: 700)

    result = query(platform: "ios", term: "user_ios").call
    row = result[:visitors].first

    assert_equal 900, row["total_views"], "android CH row excluded"
    assert_equal 1300, row["total_revenue"], "android PG revenue (700) excluded"
  end

  test "visitor_id param serves the details path from CH with PG revenue" do
    result = query(visitor_id: @android_visitor.id).call

    assert_equal 1, result[:visitors].size
    row = result[:visitors].first
    assert_equal 5, row["total_views"]
    assert_equal 300, row["total_revenue"]
    assert_equal "android", row["platform"]
  end

  test "visitor with no rollup rows in range yields an empty page (details zero-fill contract)" do
    quiet = Visitor.create!(project: @project, device: devices(:ios_device), web_visitor: false,
                            sdk_identifier: "quiet_user", uuid: SecureRandom.uuid)

    result = query(visitor_id: quiet.id).call

    assert_empty result[:visitors]
  end

  test "pagination follows the CH order across pages" do
    page1 = query(sort_by: "views", ascendent: false, per_page: 1, page: 1).call
    page2 = query(sort_by: "views", ascendent: false, per_page: 1, page: 2).call

    assert_equal [@ios_visitor.id], page1[:visitors].map { |v| v["id"] }
    assert_equal [@android_visitor.id], page2[:visitors].map { |v| v["id"] }
    assert_equal 2, page1[:meta][:total_pages]
  end

  test "term matches beyond the cap fall back to PG" do
    q = query(term: "user_", sort_by: "views", ascendent: false)

    result = q.stub(:term_id_cap, 1) { q.call } # "user_" matches both visitors

    assert_equal 130, result[:visitors].first["total_views"].to_i, "PG path must serve PG sums"
    assert_equal 2, result[:meta][:total_entries]
  end

  test "sdk_identifier sort orders in CH and serves CH metrics" do
    result = query(sort_by: "sdk_identifier", ascendent: true).call

    assert_equal [@android_visitor.id, @ios_visitor.id], result[:visitors].map { |v| v["id"] },
                 "user_android sorts before user_ios"
    assert_equal 900, result[:visitors].last["total_views"], "metrics must come from CH (PG says 130)"
    assert_equal 2, result[:meta][:total_entries]
  end

  # Parity: identity sorting moved stores, so PG and CH must agree on order, paging and totals.
  test "sdk_identifier ascending returns the same order on the PG and CH paths" do
    assert_same_on_both_paths(sort_by: "sdk_identifier", ascendent: true)
  end

  test "sdk_identifier descending returns the same order on the PG and CH paths" do
    assert_same_on_both_paths(sort_by: "sdk_identifier", ascendent: false)
  end

  test "uuid sorting returns the same order on the PG and CH paths" do
    assert_same_on_both_paths(sort_by: "uuid", ascendent: true)
    assert_same_on_both_paths(sort_by: "uuid", ascendent: false)
  end

  test "term-filtered identity sorting matches on the PG and CH paths" do
    assert_same_on_both_paths(sort_by: "sdk_identifier", ascendent: true, term: "user_")
    assert_same_on_both_paths(sort_by: "sdk_identifier", ascendent: true, term: "user_ios")
  end

  test "identity sort paging matches page-for-page on the PG and CH paths" do
    assert_same_on_both_paths(sort_by: "sdk_identifier", ascendent: true, per_page: 1, page: 1)
    assert_same_on_both_paths(sort_by: "sdk_identifier", ascendent: true, per_page: 1, page: 2)
  end

  test "identity sort agrees across paths when a third visitor is added" do
    extra = Visitor.create!(project: @project, device: devices(:ios_device), web_visitor: false,
                            sdk_identifier: "mmm_middle", uuid: SecureRandom.uuid)
    insert_visitor_metrics([row(extra.id, "2026-03-01", "ios", views: 11)])
    seed_profiles(extra)
    VisitorDailyStatistic.create!(project_id: @project.id, visitor_id: extra.id, platform: "ios",
                                  event_date: Date.parse("2026-03-01"), views: 11)

    assert_same_on_both_paths(sort_by: "sdk_identifier", ascendent: true)
  end

  # The snapshot is only as fresh as the last manual sync; the live-written profile must win.
  test "a visitor created after the identity sync is sortable and searchable" do
    newcomer = Visitor.create!(project: @project, device: devices(:ios_device), web_visitor: false,
                               sdk_identifier: "aaa_newcomer", uuid: SecureRandom.uuid)
    insert_visitor_metrics([row(newcomer.id, "2026-03-01", "ios", views: 3)])
    VisitorDailyStatistic.create!(project_id: @project.id, visitor_id: newcomer.id, platform: "ios",
                                  event_date: Date.parse("2026-03-01"), views: 3)
    # No re-sync: only the live user_profiles writer knows about this visitor.
    insert_ch_user_profiles([{
      project_id: @project.id, visitor_id: newcomer.id,
      sdk_identifier: newcomer.sdk_identifier, uuid: newcomer.uuid,
      first_seen: "2026-03-01 00:00:00.000", last_seen: live_write_time, platform: "ios"
    }])

    ids = query(sort_by: "sdk_identifier", ascendent: true).call[:visitors].map { |v| v["id"] }
    assert_equal newcomer.id, ids.first, "post-sync visitor must sort by its identifier, not blank"

    found = query(sort_by: "sdk_identifier", ascendent: true, term: "aaa_newcomer").call
    assert_equal [newcomer.id], found[:visitors].map { |v| v["id"] }, "must be searchable without a re-sync"
  end

  test "an identifier changed after the sync sorts and searches by the new value" do
    @ios_visitor.update!(sdk_identifier: "aaa_renamed")
    insert_ch_user_profiles([{
      project_id: @project.id, visitor_id: @ios_visitor.id,
      sdk_identifier: "aaa_renamed", uuid: @ios_visitor.uuid,
      first_seen: "2026-03-01 00:00:00.000", last_seen: live_write_time, platform: "ios"
    }])

    ids = query(sort_by: "sdk_identifier", ascendent: true).call[:visitors].map { |v| v["id"] }
    assert_equal @ios_visitor.id, ids.first, "the newer live value must beat the stale snapshot"

    found = query(sort_by: "sdk_identifier", ascendent: true, term: "aaa_renamed").call
    assert_equal [@ios_visitor.id], found[:visitors].map { |v| v["id"] }
    assert_empty query(sort_by: "sdk_identifier", ascendent: true, term: "user_ios_abc").call[:visitors],
                 "the superseded identifier must stop matching"
  end

  # The profile backfill is additive, so a pre-existing blank profile row never self-repairs.
  test "identity sorting ignores a stale user_profiles row and uses the synced identity" do
    insert_ch_user_profiles([{
      project_id: @project.id, visitor_id: @ios_visitor.id,
      sdk_identifier: "", uuid: "",
      first_seen: "2026-03-01 00:00:00.000", last_seen: "2026-03-02 12:00:00.000",
      platform: "ios"
    }])

    assert_same_on_both_paths(sort_by: "sdk_identifier", ascendent: true)
    result = query(sort_by: "sdk_identifier", ascendent: true, term: "user_ios").call
    assert_equal [@ios_visitor.id], result[:visitors].map { |v| v["id"] },
                 "a blank profile row must not hide the visitor from search"
  end

  # An un-synced tenant must not silently return "no visitors match" for every search.
  test "a project with no published identities falls back to PG for identity sort and term search" do
    Clickhouse.with { |c| c.execute("TRUNCATE TABLE visitor_identities") }

    sorted = query(sort_by: "sdk_identifier", ascendent: true).call
    assert_equal [@android_visitor.id, @ios_visitor.id], sorted[:visitors].map { |v| v["id"] },
                 "PG must order identity sorts when CH has no profiles"
    assert_equal 130, sorted[:visitors].last["total_views"].to_i, "PG path serves PG sums"

    searched = query(sort_by: "sdk_identifier", ascendent: true, term: "user_ios").call
    assert_equal [@ios_visitor.id], searched[:visitors].map { |v| v["id"] },
                 "term search must not return zero results just because profiles are missing"
  end

  # Snapshot synced_at is ns, profile last_seen is ms; on an exact tie the live profile must win.
  test "a live profile written in the same instant as the snapshot wins the tie" do
    generation = Clickhouse.with do |c|
      c.select_value("SELECT toString(max(synced_at)) FROM visitor_identities " \
                     "WHERE project_id = #{@project.id} AND visitor_id = 0")
    end
    insert_ch_user_profiles([{
      project_id: @project.id, visitor_id: @ios_visitor.id,
      sdk_identifier: "tie_winner", uuid: @ios_visitor.uuid,
      first_seen: "2026-03-01 00:00:00.000", last_seen: generation.to_s, platform: "ios"
    }])

    found = query(sort_by: "sdk_identifier", ascendent: true, term: "tie_winner").call
    assert_equal [@ios_visitor.id], found[:visitors].map { |v| v["id"] },
                 "the live profile must win an exact observed_at tie against the snapshot"
  end

  # PG orders NULL sdk_identifier last on ASC and first on DESC; CH would put '' at the wrong end.
  test "anonymous visitors order the same on the PG and CH paths" do
    anon = Visitor.create!(project: @project, device: devices(:ios_device), web_visitor: false,
                           sdk_identifier: nil, uuid: SecureRandom.uuid)
    insert_visitor_metrics([row(anon.id, "2026-03-01", "ios", views: 4)])
    VisitorDailyStatistic.create!(project_id: @project.id, visitor_id: anon.id, platform: "ios",
                                  event_date: Date.parse("2026-03-01"), views: 4)
    seed_profiles(anon)

    assert_same_on_both_paths(sort_by: "sdk_identifier", ascendent: true)
    assert_same_on_both_paths(sort_by: "sdk_identifier", ascendent: false)
  end

  test "wildcard characters in a term behave the same on both paths" do
    Visitor.create!(project: @project, device: devices(:ios_device), web_visitor: false,
                    sdk_identifier: "50%_off", uuid: SecureRandom.uuid)

    assert_same_on_both_paths(sort_by: "sdk_identifier", ascendent: true, term: "user%ios")
    assert_same_on_both_paths(sort_by: "sdk_identifier", ascendent: true, term: "user_io")
    assert_same_on_both_paths(sort_by: "sdk_identifier", ascendent: true, term: "50%")
  end

  test "sdk_identifier sort never consults the PG candidate cap" do
    q = query(sort_by: "sdk_identifier", ascendent: true)

    # A cap of 1 used to force the PG fallback; the CH identity path must ignore it entirely.
    result = q.stub(:term_id_cap, 1) { q.call }

    assert_equal [@android_visitor.id, @ios_visitor.id], result[:visitors].map { |v| v["id"] }
    assert_equal 900, result[:visitors].last["total_views"], "still CH-served under a cap of 1"
  end

  test "sdk_identifier sort falls back to PG when the CH identity read fails" do
    q = query(sort_by: "sdk_identifier", ascendent: true)

    result = ClickhouseReadService.stub(:visitor_metrics_page_by_identity, nil) { q.call }

    assert_equal 130, result[:visitors].find { |v| v["id"] == @ios_visitor.id }["total_views"].to_i,
                 "PG path must serve PG sums"
  end

  test "a visitor with rollup rows but no profile still appears, in the blank bucket" do
    orphan = Visitor.create!(project: @project, device: devices(:ios_device), web_visitor: false,
                             sdk_identifier: "zzz_no_profile", uuid: SecureRandom.uuid)
    insert_visitor_metrics([row(orphan.id, "2026-03-01", "ios", views: 7)])

    ids = query(sort_by: "sdk_identifier", ascendent: true).call[:visitors].map { |v| v["id"] }

    assert_includes ids, orphan.id, "LEFT JOIN must not drop population lacking a profile row"
    assert_equal orphan.id, ids.last, "blank identity sorts last ascending, like a PG NULL"
  end

  test "sdk_identifier sort descending reverses the order" do
    ids = query(sort_by: "sdk_identifier", ascendent: false).call[:visitors].map { |v| v["id"] }

    assert_equal [@ios_visitor.id, @android_visitor.id], ids
  end

  test "uuid sort follows the PG uuid ordering" do
    expected = Visitor.where(id: [@ios_visitor.id, @android_visitor.id]).order(uuid: :asc).pluck(:id)

    ids = query(sort_by: "uuid", ascendent: true).call[:visitors].map { |v| v["id"] }

    assert_equal expected, ids
  end

  test "PG-ordered sort drops visitors with no CH rows in range" do
    Visitor.create!(project: @project, device: devices(:ios_device), web_visitor: false,
                    sdk_identifier: "aaa_quiet", uuid: SecureRandom.uuid)

    result = query(sort_by: "sdk_identifier", ascendent: true).call

    assert_equal [@android_visitor.id, @ios_visitor.id], result[:visitors].map { |v| v["id"] }
    assert_equal 2, result[:meta][:total_entries], "population is still CH's"
  end

  test "PG-ordered sort pages the intersection in PG order" do
    page1 = query(sort_by: "sdk_identifier", ascendent: true, per_page: 1, page: 1).call
    page2 = query(sort_by: "sdk_identifier", ascendent: true, per_page: 1, page: 2).call

    assert_equal [@android_visitor.id], page1[:visitors].map { |v| v["id"] }
    assert_equal [@ios_visitor.id], page2[:visitors].map { |v| v["id"] }
    assert_equal 2, page1[:meta][:total_pages]
  end

  test "PG-ordered sort combines the term filter with the CH population" do
    result = query(sort_by: "sdk_identifier", ascendent: true, term: "user_ios").call

    assert_equal [@ios_visitor.id], result[:visitors].map { |v| v["id"] }
    assert_equal 900, result[:visitors].first["total_views"]
  end

  test "page 0 is clamped to the first page, never read from the end" do
    page0 = query(sort_by: "sdk_identifier", ascendent: true, per_page: 1, page: 0).call
    page1 = query(sort_by: "sdk_identifier", ascendent: true, per_page: 1, page: 1).call

    assert_equal page1[:visitors].map { |v| v["id"] }, page0[:visitors].map { |v| v["id"] }
    assert_equal 1, page0[:meta][:page]
  end

  test "revenue sort stays on the PG path" do
    result = query(sort_by: "revenue", ascendent: false).call

    assert_equal @ios_visitor.id, result[:visitors].first["id"]
    assert_equal 130, result[:visitors].first["total_views"].to_i
  end

  test "falls back to PG when CH reads are disabled" do
    Rails.application.config.clickhouse_read_enabled = false # rollups flag stays ON

    result = query(sort_by: "views", ascendent: false).call

    assert_equal 130, result[:visitors].first["total_views"].to_i, "PG fallback, not zeros"
  end

  test "PG-path sorts overlay ledger revenue when flagged" do
    original = Rails.application.config.revenue_reads_from_ledger
    Rails.application.config.revenue_reads_from_ledger = true
    PurchaseEvent.delete_all # fixture rows persist across classes
    pe = PurchaseEvent.create!(
      project: @project, device: @ios_visitor.device, event_type: "buy", usd_price_cents: 4242,
      purchase_type: "one_time", processed: true, date: Time.utc(2026, 3, 1, 12),
      transaction_id: "vsq_#{SecureRandom.hex(5)}"
    )
    pe.update_columns(revenue_platform: "ios", visitor_id: @ios_visitor.id)

    result = query(sort_by: "sdk_identifier", ascendent: true).call
    ios = result[:visitors].find { |v| v["id"] == @ios_visitor.id }

    assert_equal 4242, ios["total_revenue"], "PG sort path displays ledger revenue (VDS says 1300)"
  ensure
    Rails.application.config.revenue_reads_from_ledger = original
  end

  test "ledger flag sources visitor revenue from purchase_events" do
    original = Rails.application.config.revenue_reads_from_ledger
    Rails.application.config.revenue_reads_from_ledger = true
    PurchaseEvent.delete_all # fixture rows persist across classes
    pe = PurchaseEvent.create!(
      project: @project, device: @ios_visitor.device, event_type: "buy", usd_price_cents: 4242,
      purchase_type: "one_time", processed: true, date: Time.utc(2026, 3, 1, 12),
      transaction_id: "vsq_#{SecureRandom.hex(5)}"
    )
    pe.update_columns(revenue_platform: "ios", visitor_id: @ios_visitor.id)

    result = query(sort_by: "views", ascendent: false).call

    assert_equal 4242, result[:visitors].first["total_revenue"], "ledger-sourced (VDS says 1300)"
  ensure
    Rails.application.config.revenue_reads_from_ledger = original
  end

  private

  def query(overrides = {})
    defaults = {
      start_date: Date.parse("2026-03-01"), end_date: Date.parse("2026-03-02"),
      page: 1, per_page: 20
    }
    VisitorStatisticsQuery.new(params: defaults.merge(overrides), project: @project)
  end

  def row(visitor_id, date, platform, **metrics)
    {
      project_id: @project.id, visitor_id: visitor_id, event_date: date, platform: platform,
      views: 0, opens: 0, installs: 0, reinstalls: 0, time_spent: 0,
      reactivations: 0, app_opens: 0, user_referred: 0, inviter_id: 0
    }.merge(metrics)
  end

  def insert_visitor_metrics(rows)
    Clickhouse.with { |conn| conn.insert("visitor_metrics_daily", rows) }
  end

  # Same params through both stores: ids, order, and pagination totals must be identical.
  def assert_same_on_both_paths(params)
    ch = query(params).call
    pg = with_rollups_off { query(params).call }
    label = params.inspect

    assert_equal pg[:visitors].map { |v| v["id"] }, ch[:visitors].map { |v| v["id"] },
                 "visitor order diverges between PG and CH for #{label}"
    assert_equal pg[:meta][:total_entries], ch[:meta][:total_entries],
                 "total_entries diverges between PG and CH for #{label}"
    assert_equal pg[:meta][:total_pages], ch[:meta][:total_pages],
                 "total_pages diverges between PG and CH for #{label}"
  end

  def with_rollups_off
    previous = Rails.application.config.clickhouse_analytics_rollups_read_enabled
    Rails.application.config.clickhouse_analytics_rollups_read_enabled = false
    yield
  ensure
    Rails.application.config.clickhouse_analytics_rollups_read_enabled = previous
  end

  # The live batch job stamps last_seen at write time, which is what outranks an older snapshot.
  def live_write_time = (Time.current + 1.minute).utc.strftime("%Y-%m-%d %H:%M:%S.%3N")

  # Identity sorting reads the published visitor_identities snapshot, so seed that (not profiles).
  def seed_profiles(*visitors)
    Analytics::VisitorIdentitySyncService.sync_project(@project.id)
    insert_ch_user_profiles(visitors.map do |v|
      {
        project_id: @project.id, visitor_id: v.id,
        sdk_identifier: v.sdk_identifier.to_s, uuid: v.uuid.to_s,
        first_seen: "2026-03-01 00:00:00.000", last_seen: "2026-03-01 12:00:00.000",
        platform: v.device&.platform.to_s
      }
    end)
  end
end
