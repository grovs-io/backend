# frozen_string_literal: true

require "test_helper"

# CH values differ from the PG rows (130/1300, 30/300) so each number's source is provable.
class VisitorReferralStatisticsQueryClickhouseTest < ActiveSupport::TestCase
  include ClickhouseTestHelper

  fixtures :projects, :instances, :devices, :visitors, :visitor_daily_statistics

  setup do
    skip_unless_clickhouse!
    truncate_clickhouse_tables
    @project = projects(:one)
    @ios_inviter = visitors(:ios_visitor)
    @android_inviter = visitors(:android_visitor)
    @invitee_ios = create_visitor("invitee_ios", devices(:ios_device), inviter: @ios_inviter)
    @invitee_android = create_visitor("invitee_android", devices(:android_device), inviter: @android_inviter)
    @loner = create_visitor("loner", devices(:ios_device))

    @original_read = Rails.application.config.clickhouse_read_enabled
    @original_rollups = Rails.application.config.clickhouse_analytics_rollups_read_enabled
    Rails.application.config.clickhouse_read_enabled = true
    Rails.application.config.clickhouse_analytics_rollups_read_enabled = true
    @original_ledger = Rails.application.config.revenue_reads_from_ledger
    Rails.application.config.revenue_reads_from_ledger = false

    insert_visitor_metrics([
      row(@invitee_ios.id, "2026-03-01", "ios", inviter_id: @ios_inviter.id,
          views: 900, opens: 40, installs: 13, reinstalls: 3, time_spent: 8000,
          reactivations: 1, app_opens: 30, user_referred: 6),
      row(@invitee_android.id, "2026-03-01", "android", inviter_id: @android_inviter.id, views: 5),
      row(@loner.id, "2026-03-01", "ios", views: 400)
    ])

    # PG referral rows so a fallback is distinguishable from CH zeros.
    pg_referral_row(@invitee_ios, @ios_inviter, platform: "ios", views: 130, revenue: 1300)
    pg_referral_row(@invitee_android, @android_inviter, platform: "android", views: 30, revenue: 300)
  end

  teardown do
    Rails.application.config.clickhouse_read_enabled = @original_read
    Rails.application.config.clickhouse_analytics_rollups_read_enabled = @original_rollups
    Rails.application.config.revenue_reads_from_ledger = @original_ledger
  end

  test "metric sort orders inviters by CH invited totals with revenue from PG" do
    result = query(sort_by: "views", ascendent: false).call

    assert_equal [@ios_inviter.id, @android_inviter.id], result[:visitors].map { |v| v["id"] }
    top = result[:visitors].first
    assert_equal 900, top["invited_views"], "invited views must come from CH (PG says 130)"
    assert_equal 13, top["invited_installs"]
    assert_equal 8000, top["invited_time_spent"]
    assert_equal 1300, top["invited_revenue"], "revenue still sourced from PG"
    assert_equal @ios_inviter.uuid, top["uuid"]
    assert_equal 2, result[:meta][:total_entries]
  end

  test "visitors without an inviter never appear as inviters" do
    ids = query(sort_by: "views", ascendent: false).call[:visitors].map { |v| v["id"] }

    assert_not_includes ids, @loner.id
  end

  test "visitor_id param serves the details path from CH" do
    result = query(visitor_id: @android_inviter.id).call

    assert_equal [@android_inviter.id], result[:visitors].map { |v| v["id"] }
    assert_equal 5, result[:visitors].first["invited_views"]
    assert_equal 300, result[:visitors].first["invited_revenue"]
  end

  test "a detail lookup skips the project-wide inviter population scan" do
    calls = 0
    stub = lambda do |*_args, **_kwargs|
      calls += 1
      [@ios_inviter.id]
    end

    ClickhouseReadService.stub(:inviter_population_ids, stub) do
      query(visitor_id: @android_inviter.id).call
    end

    assert_equal 0, calls, "the id is already known; the population scan buys nothing"
  end

  test "an inviter with no invited activity in range yields an empty page" do
    result = query(visitor_id: @loner.id).call

    assert_empty result[:visitors]
  end

  # The visitor_id short-circuit skips the CH population, so the ids are NOT CH-verified;
  # an empty page must report 0 entries, not 1.
  test "a PG-ordered detail lookup with no CH rows reports zero entries" do
    result = query(visitor_id: @loner.id, sort_by: "sdk_identifier", ascendent: true).call

    assert_empty result[:visitors]
    assert_equal 0, result[:meta][:total_entries]
    assert_equal 0, result[:meta][:total_pages]
  end

  # @ios_inviter is on an ios device but its invitee's events are android: the two stores
  # must still agree on who appears, or the list changes when the flag flips.
  test "platform filters the INVITER's device on both paths, not the invitee's events" do
    insert_visitor_metrics([
      row(@invitee_android.id, "2026-03-02", "android", inviter_id: @ios_inviter.id, views: 77)
    ])

    ch_ids = query(platform: "ios").call[:visitors].map { |v| v["id"] }

    Rails.application.config.clickhouse_analytics_rollups_read_enabled = false
    pg_ids = query(platform: "ios").call[:visitors].map { |v| v["id"] }

    assert_includes ch_ids, @ios_inviter.id, "inviter is on ios even though its invitee is not"
    assert_equal pg_ids.sort, ch_ids.sort
  end

  test "invited metrics stay all-platform under a platform filter, as on PG" do
    insert_visitor_metrics([
      row(@invitee_android.id, "2026-03-02", "android", inviter_id: @ios_inviter.id, views: 77)
    ])

    result = query(platform: "ios", sort_by: "views", ascendent: false).call
    ios = result[:visitors].find { |v| v["id"] == @ios_inviter.id }

    assert_equal 977, ios["invited_views"], "900 ios + 77 android invitee views"
  end

  test "sdk_identifier sort orders in PG and serves CH metrics" do
    result = query(sort_by: "sdk_identifier", ascendent: true).call

    assert_equal [@android_inviter.id, @ios_inviter.id], result[:visitors].map { |v| v["id"] }
    assert_equal 900, result[:visitors].last["invited_views"]
  end

  test "updated_at sort stays PG-ordered and serves CH metrics" do
    @ios_inviter.touch

    ids = query(sort_by: "updated_at", ascendent: false).call[:visitors].map { |v| v["id"] }

    assert_equal [@ios_inviter.id, @android_inviter.id], ids
  end

  test "default sort orders by inviter id desc (created_at proxy)" do
    ids = query.call[:visitors].map { |v| v["id"] }

    assert_equal [@ios_inviter.id, @android_inviter.id].sort.reverse, ids
  end

  test "pagination follows the CH order across pages" do
    page1 = query(sort_by: "views", ascendent: false, per_page: 1, page: 1).call
    page2 = query(sort_by: "views", ascendent: false, per_page: 1, page: 2).call

    assert_equal [@ios_inviter.id], page1[:visitors].map { |v| v["id"] }
    assert_equal [@android_inviter.id], page2[:visitors].map { |v| v["id"] }
    assert_equal 2, page1[:meta][:total_pages]
  end

  test "a deleted inviter never consumes a page slot or inflates the total" do
    # What a merge does: the merged-away inviter is deleted in PG, CH keeps its id forever.
    stale = create_visitor("stale_inviter", devices(:ios_device))
    insert_visitor_metrics([row(@loner.id, "2026-03-01", "ios", inviter_id: stale.id, views: 9_999)])
    stale.destroy

    result = query(sort_by: "views", ascendent: false, per_page: 2).call

    assert_equal [@ios_inviter.id, @android_inviter.id], result[:visitors].map { |v| v["id"] },
                 "the deleted inviter would otherwise take the top slot and leave a short page"
    assert_equal 2, result[:meta][:total_entries], "total must not count it either"
  end

  test "a merged-away inviter's invitees are credited to the survivor" do
    merged = create_visitor("merged_inviter", devices(:ios_device))
    invitee = create_visitor("invitee_of_merged", devices(:ios_device), inviter: merged)
    insert_visitor_metrics([row(invitee.id, "2026-03-01", "ios", inviter_id: merged.id, views: 50)])
    alias_visitor(merged.id, @ios_inviter.id)
    merged.destroy

    result = query(sort_by: "views", ascendent: false).call

    assert_equal [@ios_inviter.id, @android_inviter.id], result[:visitors].map { |v| v["id"] }
    assert_equal 950, result[:visitors].first["invited_views"], "900 own + 50 inherited"
    assert_equal 2, result[:meta][:total_entries]
  end

  test "a merged-away inviter is replaced by the survivor, not dropped" do
    merged = create_visitor("merged_only", devices(:ios_device))
    survivor = create_visitor("survivor_only", devices(:ios_device))
    invitee = create_visitor("invitee_of_merged_only", devices(:ios_device), inviter: merged)
    insert_visitor_metrics([row(invitee.id, "2026-03-01", "ios", inviter_id: merged.id, views: 42)])
    alias_visitor(merged.id, survivor.id)
    merged.destroy

    result = query(sort_by: "views", ascendent: false).call
    entry = result[:visitors].find { |v| v["id"] == survivor.id }

    assert entry, "the survivor inherits the referral and must appear"
    assert_equal 42, entry["invited_views"]
    assert_nil result[:visitors].find { |v| v["id"] == merged.id }
    assert_equal 3, result[:meta][:total_entries]
  end

  test "a survivor invited by the merged visitor is not credited to itself" do
    survivor = create_visitor("self_survivor", devices(:ios_device))
    merged = create_visitor("merged_self", devices(:ios_device))
    insert_visitor_metrics([row(survivor.id, "2026-03-02", "ios", inviter_id: merged.id, views: 777)])
    alias_visitor(merged.id, survivor.id)
    merged.destroy

    result = query(sort_by: "views", ascendent: false).call

    assert_nil result[:visitors].find { |v| v["id"] == survivor.id },
               "the survivor would credit itself, with PG-sourced revenue of 0 beside it"
    assert_equal 2, result[:meta][:total_entries]
  end

  test "a merged visitor invited by the survivor does not credit the survivor" do
    survivor = create_visitor("inv_survivor", devices(:ios_device))
    merged = create_visitor("inv_merged", devices(:ios_device), inviter: survivor)
    insert_visitor_metrics([row(merged.id, "2026-03-02", "ios", inviter_id: survivor.id, views: 999)])
    alias_visitor(merged.id, survivor.id)
    merged.destroy

    result = query(sort_by: "views", ascendent: false).call

    assert_nil result[:visitors].find { |v| v["id"] == survivor.id }
    assert_equal 2, result[:meta][:total_entries]
  end

  test "a self-invite with no merge behind it still counts, as in PG" do
    selfie = create_visitor("self_invite", devices(:ios_device))
    selfie.update_column(:inviter_id, selfie.id)
    insert_visitor_metrics([row(selfie.id, "2026-03-02", "ios", inviter_id: selfie.id, views: 88)])

    result = query(sort_by: "views", ascendent: false).call
    entry = result[:visitors].find { |v| v["id"] == selfie.id }

    assert entry, "no merge created this one; dropping it would diverge from the PG fallback"
    assert_equal 88, entry["invited_views"]
  end

  test "a self-invite swept into a merge stops crediting the survivor" do
    survivor = create_visitor("si_survivor", devices(:ios_device))
    selfie = create_visitor("si_selfie", devices(:ios_device))
    selfie.update_column(:inviter_id, selfie.id)
    insert_visitor_metrics([row(selfie.id, "2026-03-02", "ios", inviter_id: selfie.id, views: 888)])
    alias_visitor(selfie.id, survivor.id)
    selfie.destroy

    result = query(sort_by: "views", ascendent: false).call

    assert_nil result[:visitors].find { |v| v["id"] == survivor.id }
    assert_equal 2, result[:meta][:total_entries]
  end

  test "a PG-ordered sort folds the merged inviter too" do
    merged = create_visitor("merged_pg_sort", devices(:ios_device))
    survivor = create_visitor("survivor_pg_sort", devices(:ios_device))
    invitee = create_visitor("invitee_pg_sort", devices(:ios_device), inviter: merged)
    insert_visitor_metrics([row(invitee.id, "2026-03-01", "ios", inviter_id: merged.id, views: 64)])
    alias_visitor(merged.id, survivor.id)
    merged.destroy

    result = query(visitor_id: survivor.id, sort_by: "sdk_identifier", ascendent: true).call

    assert_equal [survivor.id], result[:visitors].map { |v| v["id"] }
    assert_equal 64, result[:visitors].first["invited_views"]
    assert_equal 1, result[:meta][:total_entries]
  end

  test "a repointed inviter stays visible on every sort, not just the metric ones" do
    # What a merge does: invitee now belongs to someone else in PG, CH keeps the old snapshot.
    @invitee_ios.update_column(:inviter_id, @android_inviter.id)

    by_metric = query(sort_by: "views", ascendent: false).call[:visitors].map { |v| v["id"] }
    by_sdk = query(sort_by: "sdk_identifier", ascendent: true).call[:visitors].map { |v| v["id"] }

    assert_includes by_metric, @ios_inviter.id, "CH still groups the event-time inviter"
    assert_equal by_metric.sort, by_sdk.sort, "both sorts must serve the same population"
  end

  test "a failed inviter population read falls back to PG" do
    q = query(sort_by: "sdk_identifier", ascendent: true)

    result = ClickhouseReadService.stub(:inviter_population_ids, nil) { q.call }

    ios = result[:visitors].find { |v| v["id"] == @ios_inviter.id }
    assert_equal 130, ios["invited_views"].to_i, "PG path, not an empty page"
  end

  test "the candidate cap counts inviters, not every visitor in the project" do
    # 5 project visitors, 2 of them inviters: a cap of 3 must NOT force the PG fallback.
    q = query(sort_by: "sdk_identifier", ascendent: true)

    result = q.stub(:term_id_cap, 3) { q.call }

    assert_equal 900, result[:visitors].last["invited_views"], "CH path, not the PG fallback"
  end

  test "revenue sort stays on the PG path" do
    result = query(sort_by: "revenue", ascendent: false).call

    assert_equal @ios_inviter.id, result[:visitors].first["id"]
    assert_equal 130, result[:visitors].first["invited_views"].to_i, "PG path must serve PG sums"
  end

  test "falls back to PG when CH reads are disabled" do
    Rails.application.config.clickhouse_read_enabled = false # rollups flag stays ON

    result = query(sort_by: "views", ascendent: false).call

    assert_equal 130, result[:visitors].first["invited_views"].to_i, "PG fallback, not zeros"
  end

  test "flag off keeps the PG path" do
    Rails.application.config.clickhouse_analytics_rollups_read_enabled = false

    result = query(sort_by: "views", ascendent: false).call

    assert_equal 130, result[:visitors].first["invited_views"].to_i
  end

  test "ledger flag sources invited revenue from purchase_events" do
    Rails.application.config.revenue_reads_from_ledger = true
    PurchaseEvent.delete_all # fixture rows persist across classes
    pe = PurchaseEvent.create!(
      project: @project, device: @invitee_ios.device, event_type: "buy", usd_price_cents: 4242,
      purchase_type: "one_time", processed: true, date: Time.utc(2026, 3, 1, 12),
      transaction_id: "vrq_#{SecureRandom.hex(5)}"
    )
    pe.update_columns(revenue_platform: "ios", visitor_id: @invitee_ios.id)

    result = query(sort_by: "views", ascendent: false).call

    assert_equal 4242, result[:visitors].first["invited_revenue"], "ledger-sourced (PG says 1300)"
  end

  private

  def query(overrides = {})
    defaults = {
      start_date: Date.parse("2026-03-01"), end_date: Date.parse("2026-03-02"),
      page: 1, per_page: 20
    }
    VisitorReferralStatisticsQuery.new(params: defaults.merge(overrides), project: @project)
  end

  def create_visitor(identifier, device, inviter: nil)
    Visitor.create!(project: @project, device: device, web_visitor: false, inviter: inviter,
                    sdk_identifier: identifier, uuid: SecureRandom.uuid)
  end

  def pg_referral_row(invitee, inviter, platform:, views:, revenue:)
    VisitorDailyStatistic.create!(
      visitor: invitee, project_id: @project.id, event_date: "2026-03-01",
      platform: platform, invited_by_id: inviter.id, views: views, revenue: revenue
    )
  end

  def row(visitor_id, date, platform, inviter_id: 0, **metrics)
    {
      project_id: @project.id, visitor_id: visitor_id, event_date: date, platform: platform,
      views: 0, opens: 0, installs: 0, reinstalls: 0, time_spent: 0,
      reactivations: 0, app_opens: 0, user_referred: 0, inviter_id: inviter_id
    }.merge(metrics)
  end

  def alias_visitor(from_id, to_id)
    Clickhouse.with do |conn|
      conn.insert("visitor_identity_map",
                  [{ project_id: @project.id, from_visitor_id: from_id, to_visitor_id: to_id,
                     updated_at: Time.current.utc.strftime("%Y-%m-%d %H:%M:%S.%3N") }])
    end
  end

  def insert_visitor_metrics(rows)
    Clickhouse.with { |conn| conn.insert("visitor_metrics_daily", rows) }
  end
end
