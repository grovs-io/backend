# frozen_string_literal: true

require "test_helper"

class LinkDimensionsTest < ActiveSupport::TestCase
  include ClickhouseTestHelper

  fixtures :projects, :instances, :domains, :links, :link_daily_statistics, :redirect_configs, :campaigns

  setup do
    skip_unless_clickhouse!
    truncate_clickhouse_tables
    @project = projects(:one)
    @basic_link = links(:basic_link)
    @campaign_link = links(:campaign_link)

    @original_read = Rails.application.config.clickhouse_read_enabled
    @original_rollups = Rails.application.config.clickhouse_analytics_rollups_read_enabled
    @original_dims = Rails.application.config.clickhouse_link_dimensions_read_enabled
    @original_write = Rails.application.config.clickhouse_write_enabled
    @original_ledger = Rails.application.config.revenue_reads_from_ledger
    Rails.application.config.clickhouse_read_enabled = true
    Rails.application.config.clickhouse_analytics_rollups_read_enabled = true
    Rails.application.config.clickhouse_write_enabled = true
    Rails.application.config.revenue_reads_from_ledger = false

    insert_link_metrics([
      row(@basic_link.id, "2026-03-01", "ios", views: 100, installs: 10),
      row(@basic_link.id, "2026-03-02", "ios", views: 200, installs: 20),
      row(@campaign_link.id, "2026-03-01", "ios", views: 5, installs: 99)
    ])
    LinkDimensionSyncService.sync_all(Link.where(domain_id: @project.domain.id).includes(:domain))
  end

  teardown do
    Rails.application.config.clickhouse_read_enabled = @original_read
    Rails.application.config.clickhouse_analytics_rollups_read_enabled = @original_rollups
    Rails.application.config.clickhouse_link_dimensions_read_enabled = @original_dims
    Rails.application.config.clickhouse_write_enabled = @original_write
    Rails.application.config.revenue_reads_from_ledger = @original_ledger
  end

  def query(overrides = {})
    campaign = overrides.delete(:campaign)
    defaults = {
      start_date: "2026-03-01", end_date: "2026-03-02",
      page: 1, per_page: 20, sort_by: "installs", ascendent: false, active: true
    }
    LinkStatisticsQuery.new(params: defaults.merge(overrides), project: @project, campaign_id: campaign)
  end

  def row(link_id, date, platform, **metrics)
    {
      project_id: @project.id, link_id: link_id, event_date: date, platform: platform,
      views: 0, opens: 0, installs: 0, reinstalls: 0, time_spent: 0,
      reactivations: 0, app_opens: 0, user_referred: 0
    }.merge(metrics)
  end

  def insert_link_metrics(rows)
    Clickhouse.with { |conn| conn.insert("link_metrics_daily", rows) }
  end

  def utf8_collation?
    ActiveRecord::Base.connection.select_value("SELECT datcollate FROM pg_database WHERE datname = current_database()").to_s.match?(/utf-?8/i)
  end

  def with_dimensions
    Rails.application.config.clickhouse_link_dimensions_read_enabled = true
    yield
  ensure
    Rails.application.config.clickhouse_link_dimensions_read_enabled = false
  end

  # The whole point: ClickHouse-only must answer exactly what the id-list path answers.
  test "the dimension path matches the id-list path across sorts, directions and pages" do
    %w[installs views].each do |metric|
      [true, false].each do |ascendent|
        (1..3).each do |page|
          params = { sort_by: metric, ascendent: ascendent, per_page: 1, page: page }
          id_list = query(params).call
          dims = with_dimensions { query(params).call }

          assert_equal id_list, dims, "#{metric} #{ascendent ? 'asc' : 'desc'} page #{page} diverged"
        end
      end
    end
  end

  test "the dimension path matches on a term search, including tags" do
    @basic_link.update!(tags: ["promo-tag"])

    [@basic_link.name.to_s[0, 3], "promo-tag", @basic_link.path.to_s[0, 3]].reject(&:blank?).each do |term|
      params = { term: term }
      assert_equal query(params).call, with_dimensions { query(params).call }, "term #{term.inspect} diverged"
    end
  end

  test "the dimension path matches when filtering by campaign and sdk_generated" do
    assert_equal query(campaign_id: nil, sdk_generated: false).call,
                 with_dimensions { query(campaign_id: nil, sdk_generated: false).call }
  end

  test "no id list is sent — the cap cannot be reached on the dimension path" do
    q = query(sort_by: "installs", ascendent: false)

    result = q.stub(:metric_sort_id_cap, 0) { with_dimensions { q.call } }

    assert_equal 3, result[:meta][:total_entries], "a cap of 0 must not affect the CH-only path"
  end

  test "a destroyed link stops matching without waiting for a rebuild" do
    with_dimensions { assert_includes query.call[:links].map { |l| l["id"] }, @campaign_link.id }

    # link_daily_statistics is id: false, so `dependent: :destroy` cannot destroy its rows.
    LinkDailyStatistic.where(link_id: @campaign_link.id).delete_all
    @campaign_link.destroy!

    with_dimensions { assert_not_includes query.call[:links].map { |l| l["id"] }, @campaign_link.id }
  end

  test "toggling active is reflected immediately, not on the next rebuild" do
    with_dimensions { assert_includes query.call[:links].map { |l| l["id"] }, @basic_link.id }

    @basic_link.update!(active: false)

    with_dimensions { assert_not_includes query.call[:links].map { |l| l["id"] }, @basic_link.id }
  end

  test "a string active=false filters the same way on both paths" do
    @basic_link.update!(active: false)
    params = { active: "false" }

    assert_equal query(params).call, with_dimensions { query(params).call }
  end

  # The CH side folds non-ASCII; Postgres only does under a UTF-8 collation, as staging/prod run.
  test "term search treats non-ASCII identically on both paths" do
    skip "database collation is C, unlike staging/production" unless utf8_collation?
    @basic_link.update!(name: "Київ промо")

    %w[київ КИЇВ Київ].each do |term|
      assert_equal query(term: term).call, with_dimensions { query(term: term).call }, "term #{term} diverged"
    end
  end

  # active is nullable in Postgres; a nil filter means IS NULL there, which UInt8 cannot express.
  test "a nil active filter stays on the id-list path" do
    ran = false

    with_dimensions do
      ClickhouseReadService.stub(:link_page_from_dimensions, ->(*) { ran = true }) do
        query(active: nil).call
      end
    end

    assert_not ran, "a nil active filter must not reach the dimension path"
  end

  test "a non-numeric id filter returns empty instead of raising" do
    result = with_dimensions { query(link_id: "not-a-number").call }

    assert_empty result[:links]
    assert_equal 0, result[:meta][:total_entries]
  end

  test "hydration is project-scoped so a moved link cannot leak another project's metadata" do
    other = projects(:two)
    LinkDimensionSyncService.sync_all(Link.where(id: @basic_link.id).includes(:domain))
    @basic_link.update!(domain_id: other.domain.id)

    ids = with_dimensions { query.call[:links].map { |l| l["id"] } }

    assert_not_includes ids, @basic_link.id, "a link that moved projects must not hydrate here"
  end

  test "all: true sizes itself from the ClickHouse count, not Postgres" do
    result = with_dimensions { query(all: true).call }

    assert_equal 1, result[:meta][:total_pages]
    assert_equal result[:meta][:total_entries], result[:meta][:per_page]
  end

  test "reconciliation tombstones dimensions Postgres no longer has" do
    orphan_id = Link.maximum(:id).to_i + 5_000
    Clickhouse.with do |conn|
      conn.insert("link_dimensions", [{ project_id: @project.id, link_id: orphan_id, active: 1,
                                        deleted: 0, version: 1.hour.ago.utc.strftime("%Y-%m-%d %H:%M:%S.%L") }])
    end
    assert_includes ClickhouseReadService.link_dimension_ids(@project.id), orphan_id

    Rails.application.config.clickhouse_link_dimensions_read_enabled = true
    begin
      ReconcileLinkDimensionsJob.new.perform
    ensure
      Rails.application.config.clickhouse_link_dimensions_read_enabled = false
    end

    assert_not_includes ClickhouseReadService.link_dimension_ids(@project.id), orphan_id
  end

  test "reconciliation revives a link a wrong tombstone buried" do
    # Ordered explicitly: row older than tombstone, tombstone older than the run.
    Clickhouse.with { |conn| conn.execute("TRUNCATE TABLE link_dimensions") }
    @basic_link.update_column(:updated_at, 1.hour.ago)
    LinkDimensionSyncService.sync_all(Link.where(id: @basic_link.id).includes(:domain))
    Clickhouse.with do |conn|
      conn.insert("link_dimensions", [{ project_id: @project.id, link_id: @basic_link.id, active: 1,
                                        deleted: 1, version: 30.minutes.ago.utc.strftime("%Y-%m-%d %H:%M:%S.%L") }])
    end
    assert_not_includes ClickhouseReadService.link_dimension_ids(@project.id), @basic_link.id

    with_dimensions { ReconcileLinkDimensionsJob.new.perform }

    assert_includes ClickhouseReadService.link_dimension_ids(@project.id), @basic_link.id,
                    "a revival carrying the link's older updated_at would lose to the tombstone forever"
  end

  test "a failed dimension write fails the run instead of advancing the sweep cursor" do
    REDIS.del(ReconcileLinkDimensionsJob::SWEEP_CURSOR_KEY)

    LinkDimensionSyncService.stub(:sync_all, ->(*, **) { raise ClickHouse::Client::DatabaseError, "down" }) do
      with_dimensions do
        assert_raises(ClickHouse::Client::DatabaseError) { ReconcileLinkDimensionsJob.new.perform }
      end
    end

    assert_nil REDIS.get(ReconcileLinkDimensionsJob::SWEEP_CURSOR_KEY)
  end

  test "releasing an expired lock cannot delete a successor's lock" do
    job = ReconcileLinkDimensionsJob.new
    assert job.send(:acquire_lock)
    REDIS.set(ReconcileLinkDimensionsJob::LOCK_KEY, "successor-token")

    job.send(:release_lock)

    assert_equal "successor-token", REDIS.get(ReconcileLinkDimensionsJob::LOCK_KEY)
  end

  test "a stale write cannot overwrite a newer one" do
    @basic_link.update!(name: "newest")
    stale = Link.find(@basic_link.id)
    stale.name = "stale"
    stale.updated_at = 1.hour.ago

    LinkDimensionSyncService.sync(stale)

    rows = Clickhouse.with do |conn|
      conn.select_all("SELECT name FROM link_dimensions FINAL WHERE link_id = #{@basic_link.id}")
    end
    assert_equal "newest", rows.first["name"]
  end

  test "a dimension read failure falls back to the id-list path instead of erroring" do
    expected = query.call

    result = with_dimensions do
      ClickhouseReadService.stub(:link_page_from_dimensions, nil) { query.call }
    end

    assert_equal expected, result, "the id-list path must still answer when the dimension read fails"
  end

  test "destroying a campaign stops its links matching that campaign filter" do
    campaign = campaigns(:one)
    @campaign_link.update!(campaign_id: campaign.id)
    with_dimensions do
      assert_includes query(campaign: campaign.id).call[:links].map { |l| l["id"] }, @campaign_link.id
    end

    campaign.destroy!

    with_dimensions do
      assert_empty query(campaign: campaign.id).call[:links]
    end
  end

  test "a bulk link delete tombstones its dimensions" do
    ids = [@campaign_link.id]
    LinkDimensionSyncService.tombstone_missing(@project.id, ids)

    assert_not_includes ClickhouseReadService.link_dimension_ids(@project.id), @campaign_link.id
  end

  test "reconciliation re-syncs links Postgres has but ClickHouse is missing" do
    Clickhouse.with { |conn| conn.execute("TRUNCATE TABLE link_dimensions") }
    assert_empty ClickhouseReadService.link_dimension_ids(@project.id)

    Rails.application.config.clickhouse_link_dimensions_read_enabled = true
    begin
      ReconcileLinkDimensionsJob.new.perform
    ensure
      Rails.application.config.clickhouse_link_dimensions_read_enabled = false
    end

    assert_includes ClickhouseReadService.link_dimension_ids(@project.id), @basic_link.id
  end

  test "a link edit that fails to reach ClickHouse never breaks the edit" do
    Clickhouse.stub(:with, ->(*) { raise ClickHouse::Client::DatabaseError, "down" }) do
      assert_nothing_raised { @basic_link.update!(name: "renamed while CH is down") }
    end

    assert_equal "renamed while CH is down", @basic_link.reload.name
  end

  test "the attribute sweep cannot bury an edit made while it was running" do
    REDIS.del(ReconcileLinkDimensionsJob::SWEEP_CURSOR_KEY)
    @basic_link.update_columns(name: "stale", updated_at: 1.hour.ago)
    LinkDimensionSyncService.sync_all(Link.where(id: @basic_link.id).includes(:domain))
    Clickhouse.with do |conn|
      conn.insert("link_dimensions", [{ project_id: @project.id, link_id: @basic_link.id, active: 1, deleted: 0,
                                        name: "newest", version: Time.current.utc.strftime("%Y-%m-%d %H:%M:%S.%6N") }])
    end

    with_dimensions { ReconcileLinkDimensionsJob.new.perform }

    rows = Clickhouse.with do |conn|
      conn.select_all("SELECT name FROM link_dimensions FINAL WHERE link_id = #{@basic_link.id}")
    end
    assert_equal "newest", rows.first["name"], "a sweep versioned at delivery time outranks the real edit"
  end

  test "boot refuses dimension reads without the ClickHouse write and read flags" do
    assert_nothing_raised { Clickhouse.validate_link_dimensions_wiring!(reads: true, writes: true, ch_reads: true) }
    assert_nothing_raised { Clickhouse.validate_link_dimensions_wiring!(reads: false, writes: false, ch_reads: false) }
    assert_raises(RuntimeError) { Clickhouse.validate_link_dimensions_wiring!(reads: true, writes: false, ch_reads: true) }
    assert_raises(RuntimeError) { Clickhouse.validate_link_dimensions_wiring!(reads: true, writes: true, ch_reads: false) }
  end

  test "boot refuses analytics rollup/attribution reads without the ClickHouse write and read flags" do
    assert_nothing_raised { Clickhouse.validate_analytics_reads_wiring!(reads: false, writes: false, ch_reads: false) }
    assert_nothing_raised { Clickhouse.validate_analytics_reads_wiring!(reads: true, writes: true, ch_reads: true) }
    assert_raises(RuntimeError) { Clickhouse.validate_analytics_reads_wiring!(reads: true, writes: false, ch_reads: true) }
    assert_raises(RuntimeError) { Clickhouse.validate_analytics_reads_wiring!(reads: true, writes: true, ch_reads: false) }
  end

  test "a reconciler that lost its lock stops instead of running beside the winner" do
    job = ReconcileLinkDimensionsJob.new
    assert job.send(:acquire_lock)
    REDIS.set(ReconcileLinkDimensionsJob::LOCK_KEY, "successor-token")

    assert_raises(ReconcileLinkDimensionsJob::LockLost) { job.send(:renew_lock) }
  end
end
