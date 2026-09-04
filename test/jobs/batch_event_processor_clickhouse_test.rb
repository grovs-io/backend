# frozen_string_literal: true

require "test_helper"

class BatchEventProcessorClickhouseTest < ActiveSupport::TestCase
  include ClickhouseTestHelper

  fixtures :instances, :projects, :devices, :visitors, :links, :domains, :redirect_configs, :events,
           :visitor_daily_statistics, :link_daily_statistics

  setup do
    skip_unless_clickhouse!

    @job = BatchEventProcessorJob.new
    @job.jid = "ch-test-jid-#{SecureRandom.hex(4)}"
    @project = projects(:one)
    @device = devices(:ios_device)
    @android_device = devices(:android_device)
    @visitor = visitors(:ios_visitor)
    @link = links(:basic_link)

    # Clear Redis state before each test so parallel runs and prior failures
    # don't leak dedup keys or stale processing state into this test.
    REDIS.with do |conn|
      conn.del(BatchEventProcessorJob::REDIS_KEY)
      conn.del("events:dedup:#{@project.id}:#{@device.id}:view")
      conn.del("events:dedup:#{@project.id}:#{@android_device.id}:view")
    end

    @original_ch_enabled = Rails.application.config.clickhouse_write_enabled
    Rails.application.config.clickhouse_write_enabled = true
  end

  teardown do
    Rails.application.config.clickhouse_write_enabled = @original_ch_enabled if defined?(@original_ch_enabled)
    REDIS.with do |conn|
      conn.del(BatchEventProcessorJob::REDIS_KEY)
      conn.del("events:processing:#{@job.jid}") if @job
      conn.del("events:heartbeat:#{@job.jid}") if @job
      conn.del("events:dedup:#{@project.id}:#{@device.id}:view") if @device
      conn.del("events:dedup:#{@project.id}:#{@android_device.id}:view") if @android_device
      # Clean up crash recovery dedup keys so tests don't interfere with each other
      keys = conn.keys("#{BatchEventProcessorJob::CH_BATCH_DONE_PREFIX}:*")
      conn.del(*keys) if keys.any?
    end
  end

  # 1. Basic roundtrip
  test "dual_write_events_land_in_clickhouse" do
    event_date = 1.hour.from_now.iso8601
    event_json = {
      type: Grovs::Events::OPEN, project_id: @project.id, device_id: @device.id,
      data: nil, link_id: @link.id, engagement_time: nil, created_at: event_date
    }.to_json

    assert_difference "Event.count", 1 do
      @job.send(:process_batch, [event_json])
    end

    count = ch_event_count(@project.id, event_type: Grovs::Events::OPEN)
    assert_equal 1, count, "Event should be written to ClickHouse"
  end

  # 2. CH failure doesn't crash batch processor
  test "clickhouse_failure_doesnt_crash_batch_processor" do
    event_date = 1.hour.from_now.iso8601
    event_json = {
      type: Grovs::Events::OPEN, project_id: @project.id, device_id: @device.id,
      data: nil, link_id: nil, engagement_time: nil, created_at: event_date
    }.to_json

    ClickhouseWriteService.stub(:deliver_canonical, ->(*) { raise StandardError, "CH down" }) do
      assert_difference "Event.count", 1 do
        result = @job.send(:process_batch, [event_json])
        assert_equal :success, result, "PG batch should succeed even if CH fails"
      end
    end
  end

  # 3. Visitor ID correctly populated
  test "visitor_id_correctly_populated" do
    event_date = 1.hour.from_now.iso8601
    event_json = {
      type: Grovs::Events::VIEW, project_id: @project.id, device_id: @device.id,
      data: nil, link_id: nil, engagement_time: nil, created_at: event_date
    }.to_json

    @job.send(:process_batch, [event_json])

    events = ch_select_events(@project.id, columns: %w[visitor_id event_type])
    assert_equal 1, events.size
    assert_equal @visitor.id, events.first['visitor_id']
  end

  # 4. Referral event gets referrer's device context despite device not being
  #    in the original batch. The batch only contains ios_device's INSTALL, so
  #    bulk_load_records builds devices = { ios_device.id => ios_device }.
  #    The USER_REFERRED row references @android_device.id — the device loading
  #    fix (after handle_referrals) must fetch it, or build_clickhouse_rows
  #    silently drops the row.
  test "referral_event_has_referrer_device_context" do
    referrer_device = devices(:android_device)
    referrer_visitor = visitors(:android_visitor)
    # update_column bypasses callbacks (including cache invalidation).
    # Safe here because the job loads links via DB query, not cached_find_by.
    @link.update_column(:visitor_id, referrer_visitor.id)

    event_date = 1.hour.from_now.iso8601
    install_json = {
      type: Grovs::Events::INSTALL, project_id: @project.id, device_id: @device.id,
      link_id: @link.id, data: nil, engagement_time: nil, created_at: event_date
    }.to_json

    @job.send(:process_batch, [install_json])

    ch_events = ch_select_events(@project.id,
      columns: %w[event_type device_id device_model platform visitor_id sdk_identifier sdk_attributes])

    install_row = ch_events.find { |r| r['event_type'] == Grovs::Events::INSTALL }
    referred_row = ch_events.find { |r| r['event_type'] == Grovs::Events::USER_REFERRED }

    assert install_row, "INSTALL should be in ClickHouse"
    assert referred_row, "USER_REFERRED should be in ClickHouse"

    # INSTALL row has the installer's (ios) device context
    assert_equal @device.id, install_row['device_id']
    assert_equal @device.model, install_row['device_model']

    # USER_REFERRED row has the referrer's (android) device context —
    # only possible if the device loading fix fetched android_device
    assert_equal referrer_device.id, referred_row['device_id']
    assert_equal referrer_device.model, referred_row['device_model'],
      "USER_REFERRED must have referrer's device model, not installer's"
    assert_equal referrer_device.platform, referred_row['platform'],
      "USER_REFERRED must have referrer's platform, not installer's"

    # USER_REFERRED row has the referrer's visitor context —
    # only possible if referrer visitors were merged into visitors_index
    assert_equal referrer_visitor.id, referred_row['visitor_id'],
      "USER_REFERRED must have referrer's visitor_id, not 0"
    assert_equal referrer_visitor.sdk_identifier, referred_row['sdk_identifier'],
      "USER_REFERRED must have referrer's sdk_identifier"
  end

  # 5. Properties JSON preserved
  test "properties_json_preserved" do
    event_date = 1.hour.from_now.iso8601
    event_data = { "screen" => "home", "action" => "tap" }
    event_json = {
      type: Grovs::Events::OPEN, project_id: @project.id, device_id: @device.id,
      data: event_data, link_id: nil, engagement_time: nil, created_at: event_date
    }.to_json

    @job.send(:process_batch, [event_json])

    events = ch_select_events(@project.id, columns: %w[properties])
    assert_equal 1, events.size
    props = events.first['properties']
    assert_equal "home", props["screen"]
    assert_equal "tap", props["action"]
  end

  # 6. CH disabled skips write
  test "clickhouse_disabled_skips_write" do
    Rails.application.config.clickhouse_write_enabled = false

    event_date = 1.hour.from_now.iso8601
    event_json = {
      type: Grovs::Events::OPEN, project_id: @project.id, device_id: @device.id,
      data: nil, link_id: nil, engagement_time: nil, created_at: event_date
    }.to_json

    assert_difference "Event.count", 1 do
      @job.send(:process_batch, [event_json])
    end

    count = ch_event_count(@project.id)
    assert_equal 0, count, "No CH writes when feature flag is off"
  end

  # 7. Device context denormalized
  test "device_context_denormalized" do
    event_date = 1.hour.from_now.iso8601
    event_json = {
      type: Grovs::Events::OPEN, project_id: @project.id, device_id: @device.id,
      data: nil, link_id: nil, engagement_time: nil, created_at: event_date
    }.to_json

    @job.send(:process_batch, [event_json])

    events = ch_select_events(@project.id, columns: %w[device_model timezone language platform])
    assert_equal 1, events.size

    ch_event = events.first
    assert_equal @device.model, ch_event['device_model']
    assert_equal @device.timezone, ch_event['timezone']
    assert_equal @device.language, ch_event['language']
    assert_equal @device.platform, ch_event['platform']
  end

  # 8. GeoIP resolution (graceful when DB missing)
  test "geoip_resolution" do
    event_date = 1.hour.from_now.iso8601
    event_json = {
      type: Grovs::Events::OPEN, project_id: @project.id, device_id: @device.id,
      data: nil, link_id: nil, engagement_time: nil, created_at: event_date
    }.to_json

    # GeoIP may not have a real DB in test; verify we get strings (possibly empty)
    @job.send(:process_batch, [event_json])

    events = ch_select_events(@project.id, columns: %w[country city])
    assert_equal 1, events.size
    assert_kind_of String, events.first['country']
    assert_kind_of String, events.first['city']
  end

  # 9. Marketing attribution denormalized
  test "marketing_attribution_denormalized" do
    event_date = 1.hour.from_now.iso8601
    event_json = {
      type: Grovs::Events::OPEN, project_id: @project.id, device_id: @device.id,
      data: nil, link_id: @link.id, engagement_time: nil, created_at: event_date
    }.to_json

    @job.send(:process_batch, [event_json])

    events = ch_select_events(@project.id, columns: %w[tracking_source tracking_medium tracking_campaign ads_platform link_tags])
    assert_equal 1, events.size

    ch_event = events.first
    assert_equal @link.tracking_source, ch_event['tracking_source']
    assert_equal @link.tracking_medium, ch_event['tracking_medium']
    assert_equal @link.tracking_campaign, ch_event['tracking_campaign']
    assert_equal @link.ads_platform.to_s, ch_event['ads_platform']
    assert_equal @link.tags, ch_event['link_tags']
  end

  test "process_batch preserves analytics-critical SDK fields in ClickHouse" do
    @link.update!(
      tracking_source: "newsletter",
      tracking_medium: "email",
      tracking_campaign: "summer",
      ads_platform: "meta",
      tags: ["paid", "launch"]
    )
    timestamp = 1.hour.from_now.iso8601(3)
    event_json = {
      type: Grovs::Events::CUSTOM,
      project_id: @project.id,
      device_id: @device.id,
      data: { "plan" => "pro", "amount" => 1299, "screen_name" => "Checkout" },
      link_id: @link.id,
      engagement_time: 1234,
      created_at: timestamp,
      event_name: "purchase_completed",
      session_id: "sess_contract_1",
      tags: ["checkout", "revenue"]
    }.to_json

    assert_difference "Event.count", 1 do
      @job.send(:process_batch, [event_json])
    end

    events = ch_select_events(@project.id,
      columns: %w[event_type event_name screen_name visitor_id session_id device_id
                  link_id campaign_id tracking_source tracking_medium tracking_campaign
                  ads_platform link_tags engagement_time properties tags])
    ch_event = events.find { |row| row["session_id"] == "sess_contract_1" }

    assert ch_event, "expected process_batch to dual-write the SDK event to ClickHouse"
    assert_equal Grovs::Events::CUSTOM, ch_event["event_type"]
    assert_equal "purchase_completed", ch_event["event_name"]
    assert_equal "Checkout", ch_event["screen_name"],
      "CUSTOM events carry the screen they occurred on from properties.screen_name"
    assert_equal @visitor.id, ch_event["visitor_id"].to_i
    assert_equal @device.id, ch_event["device_id"].to_i
    assert_equal @link.id, ch_event["link_id"].to_i
    assert_equal @link.campaign_id.to_i, ch_event["campaign_id"].to_i
    assert_equal "newsletter", ch_event["tracking_source"]
    assert_equal "email", ch_event["tracking_medium"]
    assert_equal "summer", ch_event["tracking_campaign"]
    assert_equal "meta", ch_event["ads_platform"]
    assert_equal ["paid", "launch"], ch_event["link_tags"]
    assert_equal 1234, ch_event["engagement_time"].to_i
    assert_equal "pro", ch_event["properties"]["plan"]
    assert_equal 1299, ch_event["properties"]["amount"].to_i
    assert_equal ["checkout", "revenue"], ch_event["tags"]
  end

  # 10. User properties denormalized
  test "user_properties_denormalized" do
    event_date = 1.hour.from_now.iso8601
    event_json = {
      type: Grovs::Events::OPEN, project_id: @project.id, device_id: @device.id,
      data: nil, link_id: nil, engagement_time: nil, created_at: event_date
    }.to_json

    @job.send(:process_batch, [event_json])

    events = ch_select_events(@project.id, columns: %w[sdk_identifier sdk_attributes])
    assert_equal 1, events.size

    ch_event = events.first
    assert_equal @visitor.sdk_identifier, ch_event['sdk_identifier']
    expected_attrs = @visitor.sdk_attributes.is_a?(String) ? JSON.parse(@visitor.sdk_attributes) : @visitor.sdk_attributes
    assert_equal expected_attrs, ch_event['sdk_attributes']
  end

  # 11. User profile upserted
  test "user_profile_upserted" do
    event_date = 1.hour.from_now.iso8601
    event_json = {
      type: Grovs::Events::OPEN, project_id: @project.id, device_id: @device.id,
      data: nil, link_id: nil, engagement_time: nil, created_at: event_date
    }.to_json

    @job.send(:process_batch, [event_json])

    count = Clickhouse.with do |conn|
      conn.select_value("SELECT COUNT(*) FROM user_profiles WHERE project_id = #{Integer(@project.id)} AND visitor_id = #{Integer(@visitor.id)}")
    end
    assert_equal 1, count, "User profile should be upserted in ClickHouse"
  end

  # 12. PG insert not affected by CH dual-write
  test "pg_insert_not_affected" do
    event_date = 1.hour.from_now.iso8601
    event_json = {
      type: Grovs::Events::OPEN, project_id: @project.id, device_id: @device.id,
      data: nil, link_id: @link.id, engagement_time: 500, created_at: event_date
    }.to_json

    @job.send(:process_batch, [event_json])

    pg_event = Event.find_by(
      project_id: @project.id, device_id: @device.id,
      event: Grovs::Events::OPEN, created_at: Time.parse(event_date)
    )
    assert pg_event, "PG Event should be created"
    assert_equal @device.ip, pg_event.ip
    assert_equal @device.remote_ip, pg_event.remote_ip
    assert_equal @device.platform, pg_event.platform
    assert_equal @link.path, pg_event.path
    assert_equal @link.id, pg_event.link_id
    assert_equal 500, pg_event.engagement_time

    # PG event should NOT have CH-only fields
    assert_not pg_event.respond_to?(:device_model), "PG Event should not have CH-only columns"
  end

  # 13. upsert_user_profiles failure doesn't break batch
  test "upsert_user_profiles_failure_still_reports_success" do
    event_date = 1.hour.from_now.iso8601
    event_json = {
      type: Grovs::Events::OPEN, project_id: @project.id, device_id: @device.id,
      data: nil, link_id: nil, engagement_time: nil, created_at: event_date
    }.to_json

    ClickhouseWriteService.stub(:upsert_user_profiles, ->(_rows) { raise StandardError, "CH profiles down" }) do
      assert_difference "Event.count", 1 do
        result = @job.send(:process_batch, [event_json])
        assert_equal :success, result, "Batch should succeed even if user profile upsert fails"
      end
    end

    # Events should still land in CH despite profile failure
    count = ch_event_count(@project.id, event_type: Grovs::Events::OPEN)
    assert_equal 1, count, "CH events should be written even when profile upsert fails"
  end

  # 14. Each CH row gets the correct device's denormalized context
  test "multi_device_batch_maps_correct_context_per_row" do
    event_date = 1.hour.from_now.iso8601
    events = [
      { type: Grovs::Events::OPEN, project_id: @project.id, device_id: @device.id,
        data: nil, link_id: nil, engagement_time: nil, created_at: event_date }.to_json,
      { type: Grovs::Events::OPEN, project_id: @project.id, device_id: @android_device.id,
        data: nil, link_id: nil, engagement_time: nil, created_at: event_date }.to_json
    ]

    @job.send(:process_batch, events)

    ch_events = ch_select_events(@project.id, columns: %w[device_id device_model language platform])
    assert_equal 2, ch_events.size

    by_device = ch_events.index_by { |r| r['device_id'] }

    ios_row = by_device[@device.id]
    assert_equal @device.model, ios_row['device_model'], "iOS row should have iOS device model"
    assert_equal @device.language, ios_row['language']
    assert_equal @device.platform, ios_row['platform']

    android_row = by_device[@android_device.id]
    assert_equal @android_device.model, android_row['device_model'], "Android row should have Android device model"
    assert_equal @android_device.language, android_row['language']
    assert_equal @android_device.platform, android_row['platform']
  end

  # 15. Multiple events from same device produce exactly 1 user profile
  test "same_device_multiple_events_deduplicates_profile" do
    # Distinct created_at per event so all three are distinct canonical events
    # (byte-identical events would collapse under FINAL — dedup, not the concern here).
    base = 1.hour.from_now
    events = [
      { type: Grovs::Events::VIEW, project_id: @project.id, device_id: @device.id,
        data: nil, link_id: nil, engagement_time: nil, created_at: base.iso8601 }.to_json,
      { type: Grovs::Events::OPEN, project_id: @project.id, device_id: @device.id,
        data: nil, link_id: nil, engagement_time: nil, created_at: (base + 1.second).iso8601 }.to_json,
      { type: Grovs::Events::OPEN, project_id: @project.id, device_id: @device.id,
        data: nil, link_id: nil, engagement_time: nil, created_at: (base + 2.seconds).iso8601 }.to_json
    ]

    @job.send(:process_batch, events)

    # 3 distinct events in CH
    assert_equal 3, ch_event_count(@project.id)

    # But only 1 user profile row for this visitor
    profile_count = Clickhouse.with do |conn|
      conn.select_value("SELECT COUNT(*) FROM user_profiles WHERE visitor_id = #{Integer(@visitor.id)}")
    end
    assert_equal 1, profile_count, "Same visitor across 3 events should produce exactly 1 profile"
  end

  # 16. Mixed link/no-link events get correct attribution per row
  test "mixed_link_attribution_not_leaked_across_rows" do
    event_date = 1.hour.from_now.iso8601
    events = [
      { type: Grovs::Events::OPEN, project_id: @project.id, device_id: @device.id,
        data: nil, link_id: @link.id, engagement_time: nil, created_at: event_date }.to_json,
      { type: Grovs::Events::OPEN, project_id: @project.id, device_id: @device.id,
        data: nil, link_id: nil, engagement_time: nil, created_at: event_date }.to_json
    ]

    @job.send(:process_batch, events)

    ch_events = ch_select_events(@project.id, columns: %w[link_id tracking_source tracking_campaign path])
    assert_equal 2, ch_events.size

    linked = ch_events.find { |r| r['link_id'] == @link.id }
    unlinked = ch_events.find { |r| r['link_id'] == 0 }

    assert linked, "Should have one event with link"
    assert unlinked, "Should have one event without link"

    # Linked event gets attribution
    assert_equal @link.tracking_source, linked['tracking_source']
    assert_equal @link.tracking_campaign, linked['tracking_campaign']
    assert_equal @link.path, linked['path']

    # Unlinked event must NOT inherit the linked event's attribution
    assert_equal '', unlinked['tracking_source'], "No-link event should have empty tracking_source"
    assert_equal '', unlinked['tracking_campaign'], "No-link event should have empty tracking_campaign"
    assert_equal '', unlinked['path'], "No-link event should have empty path"
  end

  # 17. Realistic batch: multiple devices, event types, links, repeated visitors
  test "realistic_batch_of_ten_events" do
    android_visitor = visitors(:android_visitor)
    other_link = links(:no_custom_redirect_link) # same project as @link (domain: one → project: one)

    base = 1.hour.from_now
    events = [
      # ios_device: 5 events (VIEW, OPEN, OPEN, TIME_SPENT, VIEW) — same visitor appears 5x
      { type: Grovs::Events::VIEW, project_id: @project.id, device_id: @device.id,
        data: nil, link_id: @link.id, engagement_time: nil, created_at: (base + 0).iso8601(3) },
      { type: Grovs::Events::OPEN, project_id: @project.id, device_id: @device.id,
        data: nil, link_id: @link.id, engagement_time: nil, created_at: (base + 1).iso8601(3) },
      { type: Grovs::Events::OPEN, project_id: @project.id, device_id: @device.id,
        data: nil, link_id: nil, engagement_time: nil, created_at: (base + 2).iso8601(3) },
      { type: Grovs::Events::TIME_SPENT, project_id: @project.id, device_id: @device.id,
        data: nil, link_id: nil, engagement_time: 3000, created_at: (base + 3).iso8601(3) },
      { type: Grovs::Events::VIEW, project_id: @project.id, device_id: @device.id,
        data: nil, link_id: nil, engagement_time: nil, created_at: (base + 4).iso8601(3) },
      # android_device: 3 events — different visitor
      { type: Grovs::Events::VIEW, project_id: @project.id, device_id: @android_device.id,
        data: nil, link_id: other_link.id, engagement_time: nil, created_at: (base + 5).iso8601(3) },
      { type: Grovs::Events::OPEN, project_id: @project.id, device_id: @android_device.id,
        data: { "screen" => "home" }, link_id: nil, engagement_time: nil, created_at: (base + 6).iso8601(3) },
      { type: Grovs::Events::OPEN, project_id: @project.id, device_id: @android_device.id,
        data: nil, link_id: @link.id, engagement_time: nil, created_at: (base + 7).iso8601(3) },
      # ios_device again: 2 more events
      { type: Grovs::Events::OPEN, project_id: @project.id, device_id: @device.id,
        data: nil, link_id: @link.id, engagement_time: nil, created_at: (base + 8).iso8601(3) },
      { type: Grovs::Events::OPEN, project_id: @project.id, device_id: @device.id,
        data: nil, link_id: nil, engagement_time: nil, created_at: (base + 9).iso8601(3) }
    ].map(&:to_json)

    # VIEW dedup: ios_device gets 2 VIEWs, android gets 1. First VIEW per device
    # passes, rest are deduped within the batch. So we expect:
    #   ios: 1 VIEW + 5 non-VIEW (OPEN×4 + TIME_SPENT) = 6 PG events
    #   android: 1 VIEW + 2 non-VIEW = 3 PG events
    #   total PG = 9, total CH = 9
    # (Second ios VIEW at base+4 is intra-batch deduped)
    # Dedup keys already cleared in setup.

    pg_before = Event.count
    @job.send(:process_batch, events)
    pg_created = Event.count - pg_before

    # --- PG correctness (sanity check) ---
    assert_equal 9, pg_created, "9 PG events (1 ios VIEW deduped from 10 total)"

    # --- CH event count matches PG ---
    ch_total = ch_event_count(@project.id)
    assert_equal pg_created, ch_total, "CH event count should match PG event count"

    # --- Deduped VIEW must be absent from CH too (2 VIEWs survive: 1 ios + 1 android) ---
    ch_views = ch_event_count(@project.id, event_type: Grovs::Events::VIEW)
    assert_equal 2, ch_views, "Deduped ios VIEW should not appear in CH (1 ios + 1 android = 2)"

    # --- Each device's events have the right device context ---
    ch_events = ch_select_events(@project.id, columns: %w[device_id device_model platform visitor_id])
    ios_ch = ch_events.select { |r| r['device_id'] == @device.id }
    android_ch = ch_events.select { |r| r['device_id'] == @android_device.id }

    assert_equal 6, ios_ch.size
    assert_equal 3, android_ch.size

    ios_ch.each do |row|
      assert_equal @device.model, row['device_model'], "All ios rows should have ios device model"
      assert_equal @visitor.id, row['visitor_id'], "All ios rows should map to ios visitor"
    end
    android_ch.each do |row|
      assert_equal @android_device.model, row['device_model'], "All android rows should have android device model"
      assert_equal android_visitor.id, row['visitor_id'], "All android rows should map to android visitor"
    end

    # --- Exactly 2 user profiles, not 7 (one per unique visitor, not per event) ---
    profile_count = Clickhouse.with do |conn|
      conn.select_value("SELECT COUNT(*) FROM user_profiles WHERE project_id = #{Integer(@project.id)}")
    end
    assert_equal 2, profile_count, "2 unique visitors should produce exactly 2 profiles"
  end

  # 18. Enrichment fields flow to ClickHouse
  test "enrichment_fields_flow_to_clickhouse" do
    event_date = 1.hour.from_now.iso8601
    event_json = {
      type: Grovs::Events::CUSTOM, project_id: @project.id, device_id: @device.id,
      data: { "item" => "sku-42" }, link_id: nil, engagement_time: nil, created_at: event_date,
      event_name: "add_to_cart", session_id: "sess-ch-001", tags: ["checkout", "promo"]
    }.to_json

    assert_difference "Event.count", 1 do
      @job.send(:process_batch, [event_json])
    end

    events = ch_select_events(@project.id, columns: %w[event_type event_name session_id tags properties])
    assert_equal 1, events.size

    ch_event = events.first
    assert_equal Grovs::Events::CUSTOM, ch_event['event_type']
    assert_equal "add_to_cart", ch_event['event_name']
    assert_equal "sess-ch-001", ch_event['session_id']
    assert_equal ["checkout", "promo"], ch_event['tags']
    assert_equal "sku-42", ch_event['properties']['item']
  end

  # 19. SCREEN_VIEW event type in ClickHouse
  test "screen_view_event_in_clickhouse" do
    event_date = 1.hour.from_now.iso8601
    event_json = {
      type: Grovs::Events::SCREEN_VIEW, project_id: @project.id, device_id: @device.id,
      data: { "screen" => "settings" }, link_id: nil, engagement_time: nil, created_at: event_date,
      event_name: "screen_view", session_id: "sess-sv", tags: ["navigation"]
    }.to_json

    @job.send(:process_batch, [event_json])

    events = ch_select_events(@project.id, columns: %w[event_type event_name session_id tags])
    assert_equal 1, events.size

    ch_event = events.first
    assert_equal Grovs::Events::SCREEN_VIEW, ch_event['event_type']
    assert_equal "screen_view", ch_event['event_name']
    assert_equal "sess-sv", ch_event['session_id']
    assert_equal ["navigation"], ch_event['tags']
  end

  # 20. Old-format payload without enrichment fields defaults correctly in CH
  test "old_format_payload_defaults_enrichment_in_clickhouse" do
    event_date = 1.hour.from_now.iso8601
    event_json = {
      type: Grovs::Events::OPEN, project_id: @project.id, device_id: @device.id,
      data: nil, link_id: nil, engagement_time: nil, created_at: event_date
    }.to_json

    @job.send(:process_batch, [event_json])

    events = ch_select_events(@project.id, columns: %w[event_name session_id tags])
    assert_equal 1, events.size

    ch_event = events.first
    assert_equal "", ch_event['event_name']
    assert_equal "", ch_event['session_id']
    assert_equal [], ch_event['tags']
  end

  # 21. CH vs PG stats gap: CUSTOM events with link attribution land in CH
  #     but produce NO PG LinkDailyStatistic/VisitorDailyStatistic rows.
  #     This is intentional — custom events shouldn't inflate standard counters.
  #     Document the gap: CH aggregates will include link-attributed CUSTOM events
  #     that PG daily stats don't count.
  test "custom_event_with_link_lands_in_ch_but_not_pg_stats" do
    event_date = 1.hour.from_now.iso8601
    event_json = {
      type: Grovs::Events::CUSTOM, project_id: @project.id, device_id: @device.id,
      data: { "item" => "sku-1" }, link_id: @link.id, engagement_time: nil,
      created_at: event_date, event_name: "add_to_cart", session_id: "sess-gap", tags: ["checkout"]
    }.to_json

    link_stats_before = LinkDailyStatistic.count

    assert_difference "Event.count", 1 do
      @job.send(:process_batch, [event_json])
    end

    # PG: no stat rows created (CUSTOM not in MAPPING)
    assert_equal link_stats_before, LinkDailyStatistic.count,
      "CUSTOM events must not create PG link stats"

    # CH: event lands with full attribution
    events = ch_select_events(@project.id,
      columns: %w[event_type event_name link_id tracking_source tracking_campaign])
    assert_equal 1, events.size

    ch_event = events.first
    assert_equal Grovs::Events::CUSTOM, ch_event['event_type']
    assert_equal "add_to_cart", ch_event['event_name']
    assert_equal @link.id, ch_event['link_id'],
      "CH gets the link_id even though PG stats don't count this event"
    assert_equal @link.tracking_source, ch_event['tracking_source'],
      "CH gets attribution data that PG stats don't track for CUSTOM events"
  end

  # 22. Maximally sparse event: all optional fields nil/absent.
  #     Verifies every CH column gets a valid default — no nil-to-column-type
  #     mismatches that would cause ClickHouse insert errors.
  test "maximally_sparse_event_produces_valid_ch_defaults" do
    event_date = 1.hour.from_now.iso8601
    event_json = {
      type: Grovs::Events::OPEN, project_id: @project.id, device_id: @device.id,
      data: nil, link_id: nil, engagement_time: nil, created_at: event_date
    }.to_json

    @job.send(:process_batch, [event_json])

    events = ch_select_events(@project.id,
      columns: %w[event_type event_name session_id tags properties
                   link_id campaign_id inviter_id engagement_time
                   tracking_source tracking_medium tracking_campaign ads_platform
                   link_tags path vendor_id platform app_version build])
    assert_equal 1, events.size

    ch = events.first
    assert_equal Grovs::Events::OPEN, ch['event_type']

    # Enrichment fields default to empty
    assert_equal "", ch['event_name']
    assert_equal "", ch['session_id']
    assert_equal [], ch['tags']
    assert_equal({}, ch['properties'])

    # Nullable/zero-default integer columns
    assert_equal 0, ch['link_id']
    assert_equal 0, ch['campaign_id']
    assert_equal 0, ch['engagement_time']

    # Attribution columns empty when no link
    assert_equal "", ch['tracking_source']
    assert_equal "", ch['tracking_medium']
    assert_equal "", ch['tracking_campaign']
    assert_equal "", ch['ads_platform']
    assert_equal [], ch['link_tags']
    assert_equal "", ch['path']

    # Device columns populated from device record
    assert_equal @device.vendor, ch['vendor_id']
    assert_equal @device.platform, ch['platform']
  end

  # --- event_id ---

  test "event_id is deterministic and populated in clickhouse" do
    event_date = 1.hour.from_now
    event_json = {
      type: Grovs::Events::OPEN, project_id: @project.id, device_id: @device.id,
      data: nil, link_id: nil, engagement_time: nil, created_at: event_date.iso8601(3)
    }.to_json

    @job.send(:process_batch, [event_json])

    events = ch_select_events(@project.id, columns: %w[event_id])
    assert_equal 1, events.size

    event_id = events.first['event_id']
    assert_match(/\A[a-f0-9]{32}\z/, event_id, "event_id must be a 32-char hex MD5")
    assert_not_equal '', event_id, "event_id must not be empty"

    # Verify determinism: same inputs produce same ID
    expected_id = ClickhouseWriteService.generate_event_id(
      project_id: @project.id, device_id: @device.id, event_type: Grovs::Events::OPEN,
      created_at: Time.parse(event_date.iso8601(3)), event_name: "", session_id: "", link_id: 0
    )
    assert_equal expected_id, event_id
  end

  # --- crash recovery dedup ---

  test "crash recovery does not duplicate CH events" do
    event_date = 1.hour.from_now.iso8601(3)
    event_json = {
      type: Grovs::Events::OPEN, project_id: @project.id, device_id: @device.id,
      data: nil, link_id: @link.id, engagement_time: 0, created_at: event_date
    }.to_json

    # First process — normal
    @job.send(:process_batch, [event_json])
    count_after_first = ch_event_count(@project.id)
    assert_equal 1, count_after_first

    # Simulate crash recovery: same events re-processed by a new job instance
    job2 = BatchEventProcessorJob.new
    job2.jid = "recovery-jid-#{SecureRandom.hex(4)}"
    job2.send(:process_batch, [event_json])

    count_after_recovery = ch_event_count(@project.id)
    assert_equal 1, count_after_recovery, "Recovery should skip CH insert — events already landed"
  end

  # --- Phase 2: canonical deduped delivery ---

  test "events land in canonical store on process_batch" do
    event_date = 1.hour.from_now.iso8601(3)
    event_json = {
      type: Grovs::Events::OPEN, project_id: @project.id, device_id: @device.id,
      data: nil, link_id: @link.id, engagement_time: 0, created_at: event_date
    }.to_json

    @job.send(:process_batch, [event_json])

    count = Clickhouse.with do |conn|
      conn.select_value("SELECT count() FROM events FINAL WHERE project_id = #{Integer(@project.id)}")
    end
    assert_equal 1, count, "event should land in canonical store"
  end

  test "duplicate batch delivery collapses in canonical" do
    event_date = 1.hour.from_now.iso8601(3)
    event_json = {
      type: Grovs::Events::OPEN, project_id: @project.id, device_id: @device.id,
      data: nil, link_id: @link.id, engagement_time: 0, created_at: event_date
    }.to_json

    @job.send(:process_batch, [event_json])

    # Replay the same batch through a fresh job (crash-recovery style).
    job2 = BatchEventProcessorJob.new
    job2.jid = "canon-replay-#{SecureRandom.hex(4)}"
    job2.send(:process_batch, [event_json])

    count = Clickhouse.with do |conn|
      conn.select_value("SELECT count() FROM events FINAL WHERE project_id = #{Integer(@project.id)}")
    end
    assert_equal 1, count, "duplicate delivery must not inflate canonical counts"
  end

  # --- Deterministic content-hash identity, end-to-end through the REAL ingest path ---
  # Drive EventIngestionService.log_async (freezes the hash in frozen_ch_fields) → Redis →
  # process_batch, NOT a hand-built JSON (which would bypass the real freeze).

  test "byte-identical same-ms app_opens collapse to one canonical row (truth-first retry dedup)" do
    REDIS.del(BatchEventProcessorJob::REDIS_KEY)
    ts = 1.hour.from_now
    2.times do
      EventIngestionService.log_async(Grovs::Events::APP_OPEN, @project, @device, nil, nil, nil,
                                      created_at: ts, session_id: nil)
    end
    payloads = REDIS.lrange(BatchEventProcessorJob::REDIS_KEY, 0, -1)
    assert_equal 2, payloads.size
    @job.send(:process_batch, payloads)

    rows = Clickhouse.with do |c|
      c.select_all("SELECT event_id FROM events FINAL " \
                   "WHERE project_id = #{Integer(@project.id)} AND event_type = 'app_open'")
    end
    ids = rows.map { |r| r["event_id"] }
    assert_equal 1, ids.size, "two byte-identical same-ms app_opens are retries → must collapse to one row"
    assert_match(/\A[a-f0-9]{32}\z/, ids.first, "deterministic md5 content hash, not a UUID")
  ensure
    REDIS.del(BatchEventProcessorJob::REDIS_KEY)
  end

  test "crash recovery replays the frozen id — canonical does not duplicate (real ingest)" do
    REDIS.del(BatchEventProcessorJob::REDIS_KEY)
    EventIngestionService.log_async(Grovs::Events::OPEN, @project, @device, nil, @link, 0,
                                    created_at: 1.hour.from_now, session_id: "s1")
    payloads = REDIS.lrange(BatchEventProcessorJob::REDIS_KEY, 0, -1)
    canon = ->(c) { c.select_value("SELECT count() FROM events FINAL WHERE project_id = #{Integer(@project.id)}") }

    @job.send(:process_batch, payloads)
    first = Clickhouse.with { |c| canon.call(c) }

    job2 = BatchEventProcessorJob.new
    job2.jid = "recovery-#{SecureRandom.hex(4)}"
    job2.send(:process_batch, payloads) # same frozen payloads replayed

    again = Clickhouse.with { |c| canon.call(c) }
    assert_equal first, again, "frozen id replayed verbatim → ReplacingMergeTree dedups, no duplicate"
  ensure
    REDIS.del(BatchEventProcessorJob::REDIS_KEY)
  end

  test "heartbeat is refreshed during a slow canonical write" do
    event_date = 1.hour.from_now.iso8601(3)
    event_json = {
      type: Grovs::Events::OPEN, project_id: @project.id, device_id: @device.id,
      data: nil, link_id: nil, engagement_time: 0, created_at: event_date
    }.to_json

    heartbeats = 0
    @job.define_singleton_method(:refresh_heartbeat) { heartbeats += 1 }

    # Force the canonical insert to fail once so deliver_canonical makes a second
    # attempt — the heartbeat must be refreshed before each attempt.
    attempts = 0
    failing_once = lambda do |table, _rows|
      next nil unless table == "events"

      attempts += 1
      raise StandardError, "slow CH" if attempts < 2

      nil
    end

    ClickhouseWriteService.stub(:raw_insert, failing_once) do
      @job.send(:process_batch, [event_json])
    end

    assert heartbeats >= 2, "heartbeat must be refreshed between canonical write attempts (got #{heartbeats})"
  end

  test "canonical delivery failure routes to DLQ without crashing the batch" do
    event_date = 1.hour.from_now.iso8601(3)
    event_json = {
      type: Grovs::Events::OPEN, project_id: @project.id, device_id: @device.id,
      data: nil, link_id: nil, engagement_time: 0, created_at: event_date
    }.to_json

    REDIS.with { |c| c.del(ClickhouseWriteService::CANONICAL_DLQ_KEY) }

    # CH "down" only for the canonical table — bounded retries then DLQ.
    down = lambda do |table, rows|
      raise StandardError, "CH down" if table == "events"

      Clickhouse.with { |conn| conn.insert(table, rows.map { |r| ClickhouseWriteService.send(:format_timestamps, r) }) }
    end

    result = nil
    ClickhouseWriteService.stub(:raw_insert, down) do
      assert_difference "Event.count", 1 do
        result = @job.send(:process_batch, [event_json])
      end
    end

    assert_equal :success, result, "batch must succeed even when canonical delivery fails"
    dlq_len = REDIS.with { |c| c.llen(ClickhouseWriteService::CANONICAL_DLQ_KEY) }
    assert_equal 1, dlq_len, "failed canonical batch must be parked in DLQ exactly once"
  ensure
    REDIS.with { |c| c.del(ClickhouseWriteService::CANONICAL_DLQ_KEY) }
  end

  test "heartbeat hook is invoked exactly once per canonical delivery attempt" do
    event_date = 1.hour.from_now.iso8601(3)
    event_json = {
      type: Grovs::Events::OPEN, project_id: @project.id, device_id: @device.id,
      data: nil, link_id: nil, engagement_time: 0, created_at: event_date
    }.to_json

    heartbeats = 0
    @job.define_singleton_method(:refresh_heartbeat) { heartbeats += 1 }

    # Fail the canonical insert once so deliver_canonical makes exactly 2 attempts;
    # the heartbeat hook must fire exactly once per attempt → exactly 2 times.
    attempts = 0
    failing_once = lambda do |table, rows|
      next nil unless table == "events"

      attempts += 1
      raise StandardError, "slow CH" if attempts < 2

      Clickhouse.with { |conn| conn.insert(table, rows.map { |r| ClickhouseWriteService.send(:format_timestamps, r) }) }
    end

    ClickhouseWriteService.stub(:raw_insert, failing_once) do
      @job.send(:process_batch, [event_json])
    end

    assert_equal 2, attempts, "deliver_canonical should make exactly 2 attempts"
    assert_equal 3, heartbeats, "once per delivery attempt, plus persist_batch's transaction refresh"
  end

  test "canonical delivery failure does not crash process_batch and PG ack still happens" do
    event_date = 1.hour.from_now.iso8601(3)
    event_json = {
      type: Grovs::Events::OPEN, project_id: @project.id, device_id: @device.id,
      data: nil, link_id: nil, engagement_time: 0, created_at: event_date
    }.to_json

    REDIS.with { |c| c.del(ClickhouseWriteService::CANONICAL_DLQ_KEY) }

    # CH "down" only for the canonical table.
    down = lambda do |table, rows|
      raise StandardError, "CH down" if table == "events"

      Clickhouse.with { |conn| conn.insert(table, rows.map { |r| ClickhouseWriteService.send(:format_timestamps, r) }) }
    end

    result = nil
    ClickhouseWriteService.stub(:raw_insert, down) do
      assert_difference "Event.count", 1 do
        result = @job.send(:process_batch, [event_json])
      end
    end

    assert_equal :success, result, "process_batch must succeed even when canonical delivery fails"
    # Processing key (PG ack) must be cleared — it's deleted after the PG transaction.
    assert_equal 0, REDIS.with { |c| c.exists("events:processing:#{@job.jid}") },
      "PG ack (processing-key delete) must still happen when canonical delivery fails"
  ensure
    REDIS.with { |c| c.del(ClickhouseWriteService::CANONICAL_DLQ_KEY) }
  end

  # --- full pipeline MV integration ---

  test "full_pipeline_populates_all_materialized_views" do
    event_date = 1.hour.from_now.iso8601(3)

    # Event WITH link (should appear in project_daily + link_daily + visitor_daily)
    linked_event = {
      type: Grovs::Events::OPEN, project_id: @project.id, device_id: @device.id,
      data: nil, link_id: @link.id, engagement_time: 2000, created_at: event_date
    }.to_json

    # Event WITHOUT link (should appear in project_daily + visitor_daily, NOT link_daily)
    unlinked_event = {
      type: Grovs::Events::APP_OPEN, project_id: @project.id, device_id: @device.id,
      data: nil, link_id: nil, engagement_time: 0, created_at: event_date
    }.to_json

    @job.send(:process_batch, [linked_event, unlinked_event])
    rebuild_ch_breakdowns!

    # project_daily: 2 events (OPEN + APP_OPEN)
    pd_total = Clickhouse.with do |conn|
      conn.select_value("SELECT sum(cnt) FROM project_daily WHERE project_id = #{@project.id}")
    end
    assert_equal 2, pd_total, "project_daily should have 2 events"

    # link_daily: 1 event (only OPEN with link)
    ld_total = Clickhouse.with do |conn|
      conn.select_value("SELECT sum(cnt) FROM link_daily WHERE project_id = #{@project.id}")
    end
    assert_equal 1, ld_total, "link_daily should have 1 event (only linked)"

    # visitor_daily: 2 events
    vd_total = Clickhouse.with do |conn|
      conn.select_value("SELECT sum(cnt) FROM visitor_daily WHERE project_id = #{@project.id}")
    end
    assert_equal 2, vd_total, "visitor_daily should have 2 events"

    # project_country_daily: 2 events (country may be empty string from test GeoIP, but rows still land)
    pcd_total = Clickhouse.with do |conn|
      conn.select_value("SELECT sum(cnt) FROM project_country_daily WHERE project_id = #{@project.id}")
    end
    assert_equal 2, pcd_total, "project_country_daily should have 2 events"
  end
end
