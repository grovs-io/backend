# frozen_string_literal: true

# Full-stack integration test: HTTP POST → controller → Redis → BatchEventProcessorJob → PG + CH.
#
# Existing tests cover two halves:
#   - sdk_events_test.rb:    HTTP → controller → stub Redis (verifies payload shape)
#   - batch_event_processor_clickhouse_test.rb: Redis JSON → job → CH (verifies denormalization)
#
# This test closes the gap: real HTTP request through real Redis through real job into real CH.
# No stubs on the hot path. The only thing we skip is Sidekiq scheduling — we call the job inline.

require "test_helper"
require_relative "auth_test_helper"

class SdkEventsFullStackClickhouseTest < ActionDispatch::IntegrationTest
  include AuthTestHelper
  include ClickhouseTestHelper

  fixtures :instances, :projects, :applications, :ios_configurations,
           :android_configurations, :devices, :visitors, :domains, :redirect_configs, :links, :campaigns

  setup do
    skip_unless_clickhouse!

    @project = projects(:one)
    @visitor = visitors(:ios_visitor)
    @device  = devices(:ios_device)
    @link    = links(:basic_link)
    @headers = sdk_headers_for(@project, @visitor)

    @original_ch_enabled = Rails.application.config.clickhouse_write_enabled
    Rails.application.config.clickhouse_write_enabled = true

    # Clear Redis event queue so prior test state doesn't leak
    REDIS.with { |conn| conn.del(BatchEventProcessorJob::REDIS_KEY) }
  end

  teardown do
    Rails.application.config.clickhouse_write_enabled = @original_ch_enabled if defined?(@original_ch_enabled)
    REDIS.with do |conn|
      conn.del(BatchEventProcessorJob::REDIS_KEY)
      conn.del("events:processing:#{@job.jid}") if @job
      conn.del("events:heartbeat:#{@job.jid}") if @job
      conn.del("events:dedup:#{@project.id}:#{@device.id}:view") if @device
      keys = conn.keys("#{BatchEventProcessorJob::CH_BATCH_DONE_PREFIX}:*")
      conn.del(*keys) if keys.any?
    end
  end

  # Drain the Redis queue through a real BatchEventProcessorJob.
  # We pop events from Redis ourselves and call process_batch directly,
  # bypassing the 55s perform loop that would hang the test.
  def drain_event_queue!
    @job = BatchEventProcessorJob.new
    @job.jid = "fullstack-test-#{SecureRandom.hex(4)}"
    raw_events = REDIS.with { |conn| conn.lrange(BatchEventProcessorJob::REDIS_KEY, 0, -1) }
    REDIS.with { |conn| conn.del(BatchEventProcessorJob::REDIS_KEY) }
    @job.send(:process_batch, raw_events) unless raw_events.empty?
    rebuild_ch_breakdowns!
    @job
  end

  # =====================================================================
  # 1. Single system event: POST /sdk/event → Redis → Job → PG + CH
  # =====================================================================

  test "system event flows from HTTP to PG and CH" do
    post "#{SDK_PREFIX}/event",
      params: { event: Grovs::Events::OPEN },
      headers: @headers

    assert_response :ok

    # Verify event is in Redis
    queue_size = REDIS.with { |conn| conn.llen(BatchEventProcessorJob::REDIS_KEY) }
    assert_equal 1, queue_size, "Event should be in Redis pending queue"

    # Drain through job
    assert_difference "Event.count", 1 do
      drain_event_queue!
    end

    # Verify PG
    pg_event = Event.order(:created_at).last
    assert_equal Grovs::Events::OPEN, pg_event.event
    assert_equal @project.id, pg_event.project_id
    assert_equal @device.id, pg_event.device_id

    # Verify CH
    ch_rows = ch_select_events(@project.id)
    assert_equal 1, ch_rows.size
    assert_equal Grovs::Events::OPEN, ch_rows.first['event_type']
    assert_equal @device.id, ch_rows.first['device_id']
    assert_equal @project.id, ch_rows.first['project_id']
  end

  # =====================================================================
  # 2. Custom event with properties: POST /sdk/event/custom → full stack
  # =====================================================================

  test "custom event with properties flows from HTTP to CH with data intact" do
    post "#{SDK_PREFIX}/event/custom",
      params: {
        event_name: "add_to_cart",
        properties: { item_id: "sku-42", price: "19.99" },
        session_id: "sess-fullstack-001",
        tags: ["checkout", "promo"]
      },
      headers: @headers

    assert_response :ok

    drain_event_queue!

    # PG
    pg_event = Event.order(:created_at).last
    assert_equal Grovs::Events::CUSTOM, pg_event.event
    assert_equal "add_to_cart", pg_event.event_name
    assert_equal "sess-fullstack-001", pg_event.session_id

    # CH — verify enrichment fields survived the full pipeline
    ch_rows = ch_select_events(@project.id)
    assert_equal 1, ch_rows.size

    row = ch_rows.first
    assert_equal Grovs::Events::CUSTOM, row['event_type']
    assert_equal "add_to_cart", row['event_name']
    assert_equal "sess-fullstack-001", row['session_id']
    assert_includes row['tags'], "checkout"
    assert_includes row['tags'], "promo"

    # Properties should be in CH as JSON
    props = row['properties']
    props = JSON.parse(props) if props.is_a?(String)
    assert_equal "sku-42", props['item_id']
    assert_equal "19.99", props['price']
  end

  # =====================================================================
  # 3. Event with link attribution: HTTP → CH with denormalized link fields
  # =====================================================================

  test "event with link attribution denormalizes tracking fields into CH" do
    LinksService.stub(:link_for_project_and_path, ->(_proj, _path) { @link }) do
      post "#{SDK_PREFIX}/event",
        params: { event: Grovs::Events::OPEN, path: @link.path },
        headers: @headers
    end

    assert_response :ok
    drain_event_queue!

    ch_rows = ch_select_events(@project.id)
    assert_equal 1, ch_rows.size

    row = ch_rows.first
    assert_equal @link.id, row['link_id']
    assert_equal @link.tracking_source.to_s, row['tracking_source']
    assert_equal @link.tracking_campaign.to_s, row['tracking_campaign']
  end

  # =====================================================================
  # 3b. Phase 1: frozen source survives a link mutation between ingest and
  #     processing (the merge-determinism guarantee), end to end.
  # =====================================================================

  test "frozen source survives a link mutation between ingest and processing" do
    @link.update_columns(campaign_id: campaigns(:one).id, visitor_id: @visitor.id, sdk_generated: true)
    frozen_campaign = campaigns(:one).id
    frozen_link_visitor = @visitor.id

    LinksService.stub(:link_for_project_and_path, ->(_proj, _path) { @link.reload }) do
      post "#{SDK_PREFIX}/event",
        params: { event: Grovs::Events::OPEN, path: @link.path },
        headers: @headers
    end
    assert_response :ok

    # A later visitor merge repoints the link AFTER ingest, before the batch runs.
    @link.update_columns(campaign_id: campaigns(:archived_campaign).id, visitor_id: visitors(:android_visitor).id)

    drain_event_queue!

    row = ch_select_events(@project.id).first
    assert_equal frozen_campaign, row['campaign_id'].to_i, "campaign_id must be the frozen ingest-time value"
    assert_equal frozen_link_visitor, row['link_visitor_id'].to_i, "link_visitor_id must be frozen, not the merged value"
    assert_equal 1, row['sdk_generated'].to_i
  end

  # =====================================================================
  # 4. Batch endpoint: POST /sdk/events/batch → Redis → Job → PG + CH
  # =====================================================================

  test "batch of mixed events all land in PG and CH" do
    post "#{SDK_PREFIX}/events/batch",
      params: {
        events: [
          { event: "app_open", session_id: "sess-batch" },
          { event_name: "purchase", properties: { item: "gold" }, session_id: "sess-batch" },
          { event_name: "screen_view", session_id: "sess-batch" }
        ]
      },
      headers: @headers,
      as: :json

    assert_response :ok
    json = JSON.parse(response.body)
    assert_equal 3, json["accepted"]

    # All 3 should be in Redis
    queue_size = REDIS.with { |conn| conn.llen(BatchEventProcessorJob::REDIS_KEY) }
    assert_equal 3, queue_size

    assert_difference "Event.count", 3 do
      drain_event_queue!
    end

    # Verify all 3 in CH
    ch_rows = ch_select_events(@project.id)
    assert_equal 3, ch_rows.size

    types = ch_rows.map { |r| r['event_type'] }.sort
    assert_includes types, Grovs::Events::APP_OPEN
    assert_includes types, Grovs::Events::CUSTOM
    assert_includes types, Grovs::Events::SCREEN_VIEW

    # Verify custom event has properties in CH
    custom_row = ch_rows.find { |r| r['event_type'] == Grovs::Events::CUSTOM }
    props = custom_row['properties']
    props = JSON.parse(props) if props.is_a?(String)
    assert_equal "gold", props['item']

    # Verify screen_view has correct event_name
    sv_row = ch_rows.find { |r| r['event_type'] == Grovs::Events::SCREEN_VIEW }
    assert_equal "screen_view", sv_row['event_name']

    # All share same session_id
    ch_rows.each { |r| assert_equal "sess-batch", r['session_id'] }
  end

  # =====================================================================
  # 5. Device context denormalized: HTTP → CH includes device model, platform
  # =====================================================================

  test "device context is denormalized into CH row" do
    post "#{SDK_PREFIX}/event",
      params: { event: Grovs::Events::APP_OPEN },
      headers: @headers

    assert_response :ok
    drain_event_queue!

    ch_rows = ch_select_events(@project.id)
    row = ch_rows.first

    assert_equal @device.id, row['device_id']
    # Visitor should be resolved from device
    visitor = @device.visitor_for_project_id(@project.id)
    assert_equal visitor.id, row['visitor_id'] if visitor

    # Platform should match device
    assert_equal @device.platform.to_s, row['platform'] unless @device.platform.nil?

    # Powers the Device column in the events explorer — was silently '' for every event
    assert_equal @device.model.to_s, row['device_model']
  end

  # =====================================================================
  # 6. MVs populated: event from HTTP populates project_daily and visitor_daily
  # =====================================================================

  test "HTTP event populates CH materialized views" do
    post "#{SDK_PREFIX}/event",
      params: { event: Grovs::Events::OPEN },
      headers: @headers

    assert_response :ok
    drain_event_queue!

    # project_daily MV
    pd_rows = ch_query('project_daily', @project.id)
    assert pd_rows.size > 0, "project_daily should have data after HTTP event"

    open_row = pd_rows.find { |r| r['event_type'] == Grovs::Events::OPEN }
    assert open_row, "project_daily should have an OPEN row"
    assert_equal 1, open_row['cnt']

    # visitor_daily MV
    visitor = @device.visitor_for_project_id(@project.id)
    if visitor
      vd_rows = Clickhouse.with do |conn|
        conn.select_all(
          "SELECT * FROM visitor_daily WHERE project_id = #{@project.id} AND visitor_id = #{visitor.id}"
        )
      end
      assert vd_rows.size > 0, "visitor_daily should have data"
    end
  end

  # =====================================================================
  # 7. CH failure does not break HTTP response or PG persistence
  # =====================================================================

  test "CH failure during job does not affect HTTP 200 or PG event" do
    post "#{SDK_PREFIX}/event",
      params: { event: Grovs::Events::OPEN },
      headers: @headers

    assert_response :ok

    # Stub the CH write to fail during the job
    ClickhouseWriteService.stub(:deliver_canonical, ->(*) { raise StandardError, "CH down" }) do
      assert_difference "Event.count", 1 do
        drain_event_queue!
      end
    end

    # PG should have the event
    pg_event = Event.order(:created_at).last
    assert_equal Grovs::Events::OPEN, pg_event.event

    # CH should be empty (write failed)
    assert_equal 0, ch_event_count(@project.id)
  end

  # =====================================================================
  # 8. CH disabled: event still works end-to-end via PG only
  # =====================================================================

  test "CH disabled: HTTP event persists to PG only" do
    Rails.application.config.clickhouse_write_enabled = false

    post "#{SDK_PREFIX}/event",
      params: { event: Grovs::Events::APP_OPEN },
      headers: @headers

    assert_response :ok

    assert_difference "Event.count", 1 do
      drain_event_queue!
    end

    assert_equal 0, ch_event_count(@project.id), "No CH rows when disabled"
  end

  # =====================================================================
  # 9. Partially rejected batch: accepted events still reach CH
  # =====================================================================

  test "partially rejected batch: valid events reach CH, invalid ones don't" do
    post "#{SDK_PREFIX}/events/batch",
      params: {
        events: [
          { event: "app_open" },
          { neither: "event nor event_name" },
          { event_name: "valid_custom" }
        ]
      },
      headers: @headers,
      as: :json

    assert_response :ok
    json = JSON.parse(response.body)
    assert_equal 2, json["accepted"]
    assert_equal 1, json["rejected"]

    assert_difference "Event.count", 2 do
      drain_event_queue!
    end

    ch_rows = ch_select_events(@project.id)
    assert_equal 2, ch_rows.size
  end

  # =====================================================================
  # 10. User profile upserted from HTTP event
  # =====================================================================

  test "HTTP event upserts user_profile in CH" do
    post "#{SDK_PREFIX}/event",
      params: { event: Grovs::Events::OPEN },
      headers: @headers

    assert_response :ok
    drain_event_queue!

    visitor = @device.visitor_for_project_id(@project.id)
    next unless visitor

    profiles = ch_query('user_profiles', @project.id,
                        extra_where: "visitor_id = #{visitor.id}")
    assert profiles.size > 0, "user_profiles should have a row after HTTP event"
    assert_equal visitor.id, profiles.first['visitor_id']
  end

  # =====================================================================
  # 11. Multiple HTTP requests accumulate in Redis and batch-process together
  # =====================================================================

  test "multiple HTTP requests batch-process into CH in a single job run" do
    3.times do |i|
      post "#{SDK_PREFIX}/event",
        params: { event: Grovs::Events::APP_OPEN },
        headers: @headers
      assert_response :ok
    end

    queue_size = REDIS.with { |conn| conn.llen(BatchEventProcessorJob::REDIS_KEY) }
    assert_equal 3, queue_size

    assert_difference "Event.count", 3 do
      drain_event_queue!
    end

    ch_rows = ch_select_events(@project.id)
    assert_equal 3, ch_rows.size
    ch_rows.each { |r| assert_equal Grovs::Events::APP_OPEN, r['event_type'] }
  end

  # =====================================================================
  # 12. Android device: full stack with different platform
  # =====================================================================

  test "android SDK event flows through full stack with correct platform in CH" do
    android_visitor = visitors(:android_visitor)
    android_device = devices(:android_device)
    android_headers = sdk_headers_for(@project, android_visitor, platform: "android")

    post "#{SDK_PREFIX}/event",
      params: { event: Grovs::Events::OPEN },
      headers: android_headers

    assert_response :ok
    drain_event_queue!

    ch_rows = ch_select_events(@project.id)
    assert_equal 1, ch_rows.size
    assert_equal android_device.id, ch_rows.first['device_id']
    assert_equal "android", ch_rows.first['platform']
  end

  test "two same-millisecond identical events with distinct sdk ids land as two CH rows" do
    ts = "2026-08-06T12:00:00.000Z"
    post "#{SDK_PREFIX}/events/batch",
      params: { events: [
        { event: Grovs::Events::APP_OPEN, created_at: ts, session_id: "s-collapse", event_id: "fs-a" },
        { event: Grovs::Events::APP_OPEN, created_at: ts, session_id: "s-collapse", event_id: "fs-b" }
      ] },
      headers: @headers, as: :json
    assert_response :success

    drain_event_queue!

    rows = ch_select_events(@project.id).select { |r| r["session_id"] == "s-collapse" }
    assert_equal 2, rows.size, "distinct client ids must survive as distinct CH rows"
    assert_equal 2, rows.map { |r| r["event_id"] }.uniq.size
  end

  test "the same sdk id with identical content collapses to one CH row" do
    ts = "2026-08-06T12:05:00.000Z"
    2.times do
      post "#{SDK_PREFIX}/events/batch",
        params: { events: [{ event: Grovs::Events::APP_OPEN, created_at: ts, session_id: "s-retry", event_id: "fs-retry" }] },
        headers: @headers, as: :json
      assert_response :success
      drain_event_queue!
    end

    rows = ch_select_events(@project.id).select { |r| r["session_id"] == "s-retry" }
    assert_equal 1, rows.size, "a byte-identical retry must still collapse under FINAL"
  end

  test "the same sdk id with mutated content does not overwrite the stored row" do
    ts = "2026-08-06T12:10:00.000Z"
    post "#{SDK_PREFIX}/events/batch",
      params: { events: [{ event: Grovs::Events::APP_OPEN, created_at: ts, session_id: "s-mutate", event_id: "fs-mutate" }] },
      headers: @headers, as: :json
    drain_event_queue!

    post "#{SDK_PREFIX}/events/batch",
      params: { events: [{ event: Grovs::Events::APP_OPEN, created_at: ts, session_id: "s-mutate-2", event_id: "fs-mutate" }] },
      headers: @headers, as: :json
    drain_event_queue!

    sessions = ch_select_events(@project.id).map { |r| r["session_id"] }
    assert_includes sessions, "s-mutate", "the original row must survive a same-id replay with different content"
    assert_includes sessions, "s-mutate-2"
  end
end
