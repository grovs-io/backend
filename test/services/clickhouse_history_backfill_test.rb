# frozen_string_literal: true

require "test_helper"

# CH-gated: PG -> CH one-time history backfill (Phase 6). Proves a known PG event set
# backfills into canonical (deduped via event_id), rollups rebuild, parity then reports
# zero diff, and re-running the backfill is idempotent (no inflation).
class ClickhouseHistoryBackfillTest < ActiveSupport::TestCase
  include ClickhouseTestHelper

  fixtures :instances, :projects, :devices, :visitors, :domains, :redirect_configs, :campaigns

  setup do
    skip_unless_clickhouse!
    @project = projects(:one)
    @pid = @project.id
    @ios = devices(:ios_device)
    @android = devices(:android_device)
    @date = Date.new(2026, 6, 12)
    @range = [@date, @date]
    Rails.application.config.clickhouse_write_enabled = true
    Rails.application.config.clickhouse_read_enabled = true
    REDIS.with { |c| c.del(ClickhouseRollupRebuildService.dirty_key) }
    Event.where(project_id: @pid).delete_all
    DailyProjectMetric.where(project_id: @pid).delete_all
    seed_pg_events
  end

  teardown do
    REDIS.with { |c| c.del(ClickhouseRollupRebuildService.dirty_key) }
    Event.where(project_id: @pid).delete_all
  end

  test "backfill aborts when the window holds property-bearing custom events (identity overlay guard)" do
    Clickhouse.stub(:with, ->(&_b) { 3 }) do
      err = assert_raises(RuntimeError) do
        ClickhouseHistoryBackfillService.send(:assert_no_property_event_overlay!,
          Date.new(2026, 6, 1).beginning_of_day, Date.new(2026, 6, 30).end_of_day, 42)
      end
      assert_match(/property-bearing/, err.message)
      assert_match(/ALLOW_PROPERTY_EVENT_OVERLAY/, err.message)
    end
  end

  test "overlay guard passes on a clean window and with the explicit override" do
    Clickhouse.stub(:with, ->(&_b) { 0 }) do
      assert_nothing_raised do
        ClickhouseHistoryBackfillService.send(:assert_no_property_event_overlay!,
          Date.new(2026, 6, 1).beginning_of_day, Date.new(2026, 6, 30).end_of_day, nil)
      end
    end

    ENV["ALLOW_PROPERTY_EVENT_OVERLAY"] = "1"
    Clickhouse.stub(:with, ->(&_b) { 3 }) do
      assert_nothing_raised do
        ClickhouseHistoryBackfillService.send(:assert_no_property_event_overlay!,
          Date.new(2026, 6, 1).beginning_of_day, Date.new(2026, 6, 30).end_of_day, nil)
      end
    end
  ensure
    ENV.delete("ALLOW_PROPERTY_EVENT_OVERLAY")
  end

  test "backfill loads PG events into canonical and rebuilds rollups" do
    result = ClickhouseHistoryBackfillService.backfill(start_date: @date, end_date: @date, project_id: @pid)

    assert_equal 5, result.events_read
    assert_equal 5, result.rows_inserted
    assert_includes result.partitions, "202606"

    canonical = ch_canonical_count
    assert_equal 5, canonical, "all 5 PG events should land in canonical"

    # The rebuilt project rollup must reflect the backfilled counts.
    totals = ClickhouseReadService.project_metrics_daily_totals(@pid, start_date: @date, end_date: @date)
    assert_equal 3, totals[:views]
    assert_equal 1, totals[:installs]
    assert_equal 1, totals[:opens]
  end

  test "backfill RAISES when a rollup rebuild is lock-skipped (one-shot path must be complete)" do
    ClickhouseRollupRebuildService.stub(:rebuild_partition, ->(*) { false }) do
      ClickhouseRollupRebuildService.stub(:rebuild_acquisition, ->(*) { false }) do
        error = assert_raises(RuntimeError) do
          ClickhouseHistoryBackfillService.backfill(start_date: @date, end_date: @date, project_id: @pid)
        end
        assert_match(/lock held/, error.message)
      end
    end
  end

  test "backfill RAISES on a canonical insert failure (no false success, no rebuild over partial data)" do
    rebuilt = false
    ClickhouseRollupRebuildService.stub(:rebuild_partition_range, ->(*) { rebuilt = true }) do
      ClickhouseWriteService.stub(:insert_canonical_events, ->(_rows) { false }) do
        assert_raises(RuntimeError) do
          ClickhouseHistoryBackfillService.backfill(start_date: @date, end_date: @date, project_id: @pid)
        end
      end
    end
    assert_not rebuilt, "must abort before rebuilding rollups when a canonical insert fails"
  end

  test "backfill RAISES on a rollup rebuild failure (no green Result over incomplete rollups)" do
    # Rebuild runs strict:true, so a swallowed failure would otherwise return a
    # successful Result over incomplete rollups. Force one rebuild to fail.
    ClickhouseRollupRebuildService.stub(:rebuild_partition, ->(*) { raise "rebuild boom" }) do
      assert_raises(RuntimeError) do
        ClickhouseHistoryBackfillService.backfill(start_date: @date, end_date: @date, project_id: @pid)
      end
    end
  end

  test "backfill is idempotent — re-running does not inflate canonical or rollups" do
    ClickhouseHistoryBackfillService.backfill(start_date: @date, end_date: @date, project_id: @pid)
    first = ch_canonical_count
    first_totals = ClickhouseReadService.project_metrics_daily_totals(@pid, start_date: @date, end_date: @date)

    # Run it AGAIN over the same range.
    ClickhouseHistoryBackfillService.backfill(start_date: @date, end_date: @date, project_id: @pid)

    assert_equal first, ch_canonical_count, "re-running must not duplicate canonical rows (ReplacingMergeTree dedup by event_id)"
    again_totals = ClickhouseReadService.project_metrics_daily_totals(@pid, start_date: @date, end_date: @date)
    assert_equal first_totals, again_totals, "re-running must not inflate rollups"
  end

  test "parity gate reports PASS after backfill (CH rollups match the trusted oracle)" do
    ClickhouseHistoryBackfillService.backfill(start_date: @date, end_date: @date, project_id: @pid)

    # Attribution parity compares the rebuilt rollups against a trusted recompute from
    # canonical — zero diff on every model proves the backfilled rollups are faithful.
    %i[install first last].each do |model|
      report = Billing::ClickhouseParityCheck.attribution_parity(
        project_id: @pid, start_date: @date, end_date: @date, model: model
      )
      assert report.all_match?, "#{model} attribution parity must pass post-backfill: #{report.covered.inspect}"
    end

    gate = Billing::ClickhouseParityCheck.gate(
      project_id: @pid, start_date: @date, end_date: @date,
      rollups: %i[], attribution_models: %i[install first last]
    )
    assert gate.pass, "gate must PASS post-backfill: #{gate.mismatches.inspect}"
  end

  test "backfill counts events skipped because their Device is missing" do
    Event.where(project_id: @pid).delete_all
    ts = @date.to_time.change(hour: 9)
    create_event(@ios, "view", ts)
    # An event whose Device is later deleted → backfill drops it (best-effort).
    orphan = Device.create!(user_agent: "o", ip: "1.1.1.1", remote_ip: "2.2.2.2",
                            platform: "ios", vendor: "orphan-#{SecureRandom.hex(6)}")
    create_event(orphan, "view", ts + 1.minute)
    Device.where(id: orphan.id).delete_all

    result = ClickhouseHistoryBackfillService.backfill(start_date: @date, end_date: @date, project_id: @pid)

    assert_equal 2, result.events_read
    assert_equal 1, result.rows_inserted, "only the event with a present Device is inserted"
    assert_equal 1, result.skipped[:missing_device], "the orphaned-device event is counted as skipped"
  end

  test "backfill present link with a campaign freezes a NON-organic source and parity passes" do
    Event.where(project_id: @pid).delete_all
    campaign = Campaign.create!(project: @project, name: "Backfill Campaign", archived: false)
    campaign_link = build_link("bf-campaign", campaign: campaign, sdk_generated: false, visitor: nil)
    referral_link = build_link("bf-referral", campaign: nil, sdk_generated: true,
                               visitor: visitors(:android_visitor))

    ts = @date.to_time.change(hour: 11)
    create_event(@ios, "view", ts, link: campaign_link)
    create_event(@android, "view", ts + 1.minute, link: referral_link)

    ClickhouseHistoryBackfillService.backfill(start_date: @date, end_date: @date, project_id: @pid)

    # The frozen canonical rows must carry the link's attribution, classified NON-organic.
    sources = canonical_sources
    assert_includes sources, "campaigns", "campaign link must freeze the campaigns source"
    assert_includes sources, "referrals", "sdk_generated link with a visitor must freeze referrals"
    assert_not_includes sources, "organic", "a present link must not classify as organic"

    %i[install first last].each do |model|
      report = Billing::ClickhouseParityCheck.attribution_parity(
        project_id: @pid, start_date: @date, end_date: @date, model: model
      )
      assert report.all_match?, "#{model} parity must pass for present-link backfill: #{report.covered.inspect}"
    end
  end

  test "backfill reports the attribution reconstruction breakdown (best-effort floor observability)" do
    Event.where(project_id: @pid).delete_all
    campaign = Campaign.create!(project: @project, name: "Recon Campaign", archived: false)
    campaign_link = build_link("recon-campaign", campaign: campaign, sdk_generated: false, visitor: nil)
    ts = @date.to_time.change(hour: 11)
    create_event(@ios, "view", ts, link: campaign_link) # reconstructed from current link state
    create_event(@android, "open", ts + 1.minute)       # genuinely organic (no link)

    result = ClickhouseHistoryBackfillService.backfill(start_date: @date, end_date: @date, project_id: @pid)

    assert_equal 1, result.reconstruction[:link_reconstructed],
                 "a present-campaign-link event must count as reconstructed (uncertain) attribution"
    assert_equal 1, result.reconstruction[:organic], "a no-link event must count as organic"
  end

  test "backfill geos the EVENT's historical remote_ip, not the device's current IP" do
    Event.where(project_id: @pid).delete_all
    # The event carries its own historical remote_ip (a traveller's IP at event time), distinct
    # from whatever the device's current IP is. Country must reflect the EVENT's IP.
    Event.create!(project_id: @pid, device_id: @ios.id, event: "open", platform: @ios.platform,
                  remote_ip: "203.0.113.7", created_at: @date.to_time.change(hour: 9),
                  updated_at: @date.to_time.change(hour: 9))

    geo = ->(ip, **_) { ip == "203.0.113.7" ? { country: "DE", city: "" } : { country: "US", city: "" } }
    GeoipService.stub(:lookup, geo) do
      ClickhouseHistoryBackfillService.backfill(start_date: @date, end_date: @date, project_id: @pid)
    end

    rows = Clickhouse.with do |c|
      c.select_all("SELECT DISTINCT country FROM events FINAL " \
                   "WHERE project_id = #{Integer(@pid)} AND event_type = 'open'")
    end
    countries = rows.map { |r| r["country"] }
    assert_equal ["DE"], countries,
                 "canonical country must come from the event's remote_ip (203.0.113.7 → DE), not the device IP"
  end

  test "backfill carries the joined visitor's sdk_identifier onto canonical rows" do
    ClickhouseHistoryBackfillService.backfill(start_date: @date, end_date: @date, project_id: @pid)

    rows = Clickhouse.with do |conn|
      conn.select_all(
        "SELECT device_id, sdk_identifier, toString(sdk_attributes) AS attrs FROM events FINAL " \
        "WHERE project_id = #{@pid}"
      )
    end
    by_device = rows.group_by { |r| r["device_id"].to_i }

    assert_equal ["user_ios_abc123"], by_device[@ios.id].map { |r| r["sdk_identifier"] }.uniq
    assert_equal ["user_android_xyz789"], by_device[@android.id].map { |r| r["sdk_identifier"] }.uniq
  end

  # sdk_attributes are point-in-time; stamping today's onto old events rewrites segmentation.
  test "backfill leaves sdk_attributes blank rather than stamping current visitor properties on history" do
    ClickhouseHistoryBackfillService.backfill(start_date: @date, end_date: @date, project_id: @pid)

    rows = Clickhouse.with do |conn|
      conn.select_all("SELECT DISTINCT toString(sdk_attributes) AS attrs FROM events FINAL " \
                      "WHERE project_id = #{@pid}")
    end
    assert_equal ["{}"], rows.map { |r| r["attrs"] }
  end

  test "backfill leaves sdk_identifier blank when the event has no joined visitor" do
    Event.where(project_id: @pid).delete_all
    visitorless = Device.create!(user_agent: "v", ip: "1.1.1.1", remote_ip: "2.2.2.2",
                                 platform: "ios", vendor: "novis-#{SecureRandom.hex(6)}")
    create_event(visitorless, "view", @date.to_time.change(hour: 9))

    ClickhouseHistoryBackfillService.backfill(start_date: @date, end_date: @date, project_id: @pid)

    rows = Clickhouse.with do |conn|
      conn.select_all("SELECT sdk_identifier FROM events FINAL WHERE project_id = #{@pid}")
    end
    assert_equal [""], rows.map { |r| r["sdk_identifier"] }
  end

  test "backfill resolves screen_name from properties, never from current visitor attributes" do
    Event.where(project_id: @pid).delete_all
    visitors(:ios_visitor).update!(sdk_attributes: { "screen_name" => "CurrentScreen" })
    ts = @date.to_time.change(hour: 11)
    Event.create!(project_id: @pid, device_id: @ios.id, event: Grovs::Events::SCREEN_VIEW,
                  event_name: "screen_view", data: { "screen_name" => "Store" },
                  platform: @ios.platform, created_at: ts, updated_at: ts)
    Event.create!(project_id: @pid, device_id: @ios.id, event: Grovs::Events::SCREEN_VIEW,
                  event_name: "screen_view", platform: @ios.platform,
                  created_at: ts + 1.minute, updated_at: ts + 1.minute)

    ClickhouseHistoryBackfillService.backfill(start_date: @date, end_date: @date, project_id: @pid)

    rows = Clickhouse.with do |conn|
      conn.select_all("SELECT screen_name FROM events FINAL WHERE project_id = #{@pid} ORDER BY created_at")
    end
    assert_equal %w[Store screen_view], rows.map { |r| r["screen_name"] },
      "properties resolve; without them the fallback is event_name, not the visitor's mutable attrs"
  end

  test "backfill rebuild: false loads canonical but leaves rollups empty until rebuilt" do
    result = ClickhouseHistoryBackfillService.backfill(
      start_date: @date, end_date: @date, project_id: @pid, rebuild: false
    )
    assert_equal 5, result.rows_inserted
    assert_equal 5, ch_canonical_count

    totals = ClickhouseReadService.project_metrics_daily_totals(@pid, start_date: @date, end_date: @date)
    assert_equal 0, totals[:views], "rollups must be empty until rebuilt"
  end

  private

  # 5 events on @date for the project's two fixture visitors: 3 views, 1 install, 1 open.
  def seed_pg_events
    ts = @date.to_time.change(hour: 10)
    create_event(@ios, "view", ts)
    create_event(@ios, "view", ts + 1.minute)
    create_event(@ios, "install", ts + 2.minutes)
    create_event(@android, "view", ts + 3.minutes)
    create_event(@android, "open", ts + 4.minutes)
  end

  def create_event(device, event, created_at, link: nil)
    Event.create!(
      project_id: @pid, device_id: device.id, event: event, link: link,
      platform: device.platform, app_version: device.app_version,
      created_at: created_at, updated_at: created_at
    )
  end

  def build_link(path, campaign:, sdk_generated:, visitor:)
    Link.create!(
      domain: domains(:one), redirect_config: redirect_configs(:one), campaign: campaign,
      path: path, title: path, generated_from_platform: "ios", active: true,
      sdk_generated: sdk_generated, visitor: visitor, data: "[]"
    )
  end

  # The frozen source bucket per canonical row, classified by the shared taxonomy.
  def canonical_sources
    Clickhouse.with do |conn|
      conn.select_all(
        "SELECT #{Analytics::SourceTaxonomy.expr} AS source FROM events FINAL " \
        "WHERE project_id = #{@pid}"
      ).map { |r| r["source"] }
    end
  end

  def ch_canonical_count
    Clickhouse.with do |conn|
      conn.select_value("SELECT count() FROM (SELECT event_id FROM events FINAL WHERE project_id = #{@pid})").to_i
    end
  end
end
