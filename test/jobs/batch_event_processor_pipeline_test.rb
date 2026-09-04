# frozen_string_literal: true

require "test_helper"

# =============================================================================
# Pipeline integration tests: Redis → perform() → PG events + PG stats + CH
#
# Most tests push JSON into the Redis pending queue, call perform_fast(@job),
# and assert on actual DB state. perform_fast stubs only sleep and Time.current
# (to break the 55s loop after draining); the full code path from Redis Lua pop
# through parse → dedup → build → persist → CH dual-write → cleanup is real.
#
# Test 10 (cross-batch dedup) calls process_batch directly so both batches
# complete within the real 5s Redis dedup TTL — no fake key manipulation.
#
# Each test uses a unique future date (2026-07-XX) to avoid collisions with
# fixture stats from March.
# =============================================================================

module PipelineTestHelpers
  private

  # Runs perform() but breaks the 55s loop after the queue is drained.
  #
  # What's real:   Redis Lua pop, parse, dedup, build, persist, CH dual-write,
  #                processing key cleanup, heartbeat lifecycle, enqueue_if_backlog.
  # What's stubbed: sleep (no-op) and Time.current (jumps forward after drain
  #                to break the while loop).
  #
  # Known risk: Time.current is stubbed globally, not just for the deadline
  # check. Before drain, deadline_expired is false so Time.current returns
  # real time — all business logic (batch_start, batch_elapsed, heartbeat
  # refresh) sees correct timestamps. After drain the +2min jump only
  # affects the while-loop exit condition, enqueue_if_backlog (no Time use),
  # and the ensure block (heartbeat delete, no Time use). If perform gains
  # new post-loop Time.current calls, this stub may need revisiting.
  def perform_fast(job)
    original_pop = job.method(:pop_events)
    deadline_expired = false

    fast_pop = lambda { |count|
      result = original_pop.call(count)
      deadline_expired = true if result.empty?
      result
    }

    real_time = Time.method(:current)
    fast_time = lambda {
      deadline_expired ? real_time.call + 2.minutes : real_time.call
    }

    job.stub(:sleep, nil) do
      job.stub(:pop_events, fast_pop) do
        Time.stub(:current, fast_time) do
          job.perform
        end
      end
    end
  end

  def push_event(type:, device:, link: nil, created_at:, engagement_time: nil,
                 data: nil, event_name: nil, session_id: nil, tags: nil)
    REDIS.with { |conn| conn.lpush(BatchEventProcessorJob::REDIS_KEY,
                                   event_json(type: type, device: device, link: link,
                                              created_at: created_at, engagement_time: engagement_time,
                                              data: data, event_name: event_name,
                                              session_id: session_id, tags: tags)) }
  end

  # Returns a JSON string matching the format EventIngestionService.enqueue_event produces.
  # Used by push_event (Redis path) and directly by tests that call process_batch.
  def event_json(type:, device:, link: nil, created_at:, engagement_time: nil,
                 data: nil, event_name: nil, session_id: nil, tags: nil)
    payload = {
      type: type,
      project_id: @project.id,
      device_id: device.id,
      data: data,
      link_id: link&.id,
      engagement_time: engagement_time,
      created_at: created_at
    }
    payload[:event_name] = event_name if event_name
    payload[:session_id] = session_id if session_id
    payload[:tags] = tags if tags
    payload.to_json
  end
end

# rubocop:disable Metrics/ClassLength
class BatchEventProcessorPipelinePgTest < ActiveSupport::TestCase
  include PipelineTestHelpers
  fixtures :instances, :projects, :devices, :visitors, :links, :domains, :redirect_configs, :events,
           :visitor_daily_statistics, :link_daily_statistics

  setup do
    @job = BatchEventProcessorJob.new
    @job.jid = "pipeline-pg-#{SecureRandom.hex(4)}"
    @project = projects(:one)
    @device = devices(:ios_device)
    @android_device = devices(:android_device)
    @visitor = visitors(:ios_visitor)
    @android_visitor = visitors(:android_visitor)
    @link = links(:basic_link)
    @extra_jids = []

    REDIS.with do |conn|
      conn.del(BatchEventProcessorJob::REDIS_KEY)
      conn.del("events:dedup:#{@project.id}:#{@device.id}:view")
      conn.del("events:dedup:#{@project.id}:#{@android_device.id}:view")
    end
  end

  teardown do
    REDIS.with do |conn|
      conn.del(BatchEventProcessorJob::REDIS_KEY)
      ([@job&.jid] + @extra_jids).compact.each do |jid|
        conn.del("events:processing:#{jid}")
        conn.del("events:heartbeat:#{jid}")
      end
      conn.del("events:dedup:#{@project.id}:#{@device.id}:view") if @device
      conn.del("events:dedup:#{@project.id}:#{@android_device.id}:view") if @android_device
    end
  end

  # --- Test 1 ---
  test "single_open_creates_event_and_stats" do
    date = "2026-07-01T12:00:00Z"
    push_event(type: Grovs::Events::OPEN, device: @device, link: @link, created_at: date)

    assert_difference "Event.count", 1 do
      perform_fast(@job)
    end

    event = Event.find_by(project_id: @project.id, device_id: @device.id,
                          event: Grovs::Events::OPEN, created_at: Time.parse(date))
    assert event, "Event should be persisted"
    assert_equal @device.ip, event.ip
    assert_equal @device.vendor, event.vendor_id
    assert_equal @device.platform, event.platform
    assert_equal @device.app_version, event.app_version
    assert_equal @device.build, event.build
    assert_equal @link.path, event.path

    link_stat = LinkDailyStatistic.find_by(project_id: @project.id, link_id: @link.id,
                                           event_date: Date.parse("2026-07-01"),
                                           platform: @device.platform_for_metrics)
    assert link_stat
    assert_equal 1, link_stat.opens

    visitor_stat = VisitorDailyStatistic.find_by(project_id: @project.id, visitor_id: @visitor.id,
                                                 event_date: Date.parse("2026-07-01"),
                                                 platform: @device.platform_for_metrics)
    assert visitor_stat
    assert_equal 1, visitor_stat.opens

    # Redis should be fully cleaned up
    REDIS.with do |conn|
      assert_equal 0, conn.llen(BatchEventProcessorJob::REDIS_KEY), "Pending queue should be drained"
      assert_equal 0, conn.llen("events:processing:#{@job.jid}"), "Processing key should be cleaned up"
      assert_equal false, conn.exists?("events:heartbeat:#{@job.jid}"), "Heartbeat should be cleaned up"
    end
  end

  # --- Test 2 ---
  test "every_stat_mapped_type_produces_correct_counters" do
    date = "2026-07-02T12:00:00Z"
    [Grovs::Events::VIEW, Grovs::Events::OPEN, Grovs::Events::INSTALL,
     Grovs::Events::REINSTALL, Grovs::Events::APP_OPEN, Grovs::Events::REACTIVATION].each do |type|
      push_event(type: type, device: @device, link: @link, created_at: date)
    end
    push_event(type: Grovs::Events::TIME_SPENT, device: @device, link: @link,
               created_at: date, engagement_time: 4200)

    assert_difference "Event.count", 7 do
      perform_fast(@job)
    end

    stat_date = Date.parse("2026-07-02")
    platform = @device.platform_for_metrics

    link_stat = LinkDailyStatistic.find_by(project_id: @project.id, link_id: @link.id,
                                           event_date: stat_date, platform: platform)
    assert link_stat
    assert_equal 1, link_stat.views
    assert_equal 1, link_stat.opens
    assert_equal 1, link_stat.installs
    assert_equal 1, link_stat.reinstalls
    assert_equal 1, link_stat.app_opens
    assert_equal 1, link_stat.reactivations
    assert_equal 4200, link_stat.time_spent

    visitor_stat = VisitorDailyStatistic.find_by(project_id: @project.id, visitor_id: @visitor.id,
                                                 event_date: stat_date, platform: platform)
    assert visitor_stat
    assert_equal 1, visitor_stat.views
    assert_equal 1, visitor_stat.opens
    assert_equal 1, visitor_stat.installs
    assert_equal 1, visitor_stat.reinstalls
    assert_equal 1, visitor_stat.app_opens
    assert_equal 1, visitor_stat.reactivations
    assert_equal 4200, visitor_stat.time_spent
  end

  # --- Test 3 ---
  test "custom_and_screen_view_create_events_but_no_stats" do
    date = "2026-07-03T12:00:00Z"
    push_event(type: Grovs::Events::CUSTOM, device: @device, link: @link, created_at: date,
               event_name: "purchase", data: { "sku" => "42" }, session_id: "s1", tags: ["checkout"])
    push_event(type: Grovs::Events::SCREEN_VIEW, device: @device, link: @link, created_at: date,
               event_name: "screen_view", session_id: "s2", tags: ["nav"])

    link_stats_before = LinkDailyStatistic.where(event_date: Date.parse("2026-07-03")).count
    visitor_stats_before = VisitorDailyStatistic.where(event_date: Date.parse("2026-07-03")).count

    assert_difference "Event.count", 2 do
      perform_fast(@job)
    end

    # Enrichment fields persisted
    custom = Event.find_by(project_id: @project.id, event: Grovs::Events::CUSTOM,
                           created_at: Time.parse(date))
    assert_equal "purchase", custom.event_name
    assert_equal({ "sku" => "42" }, custom.data)
    assert_equal "s1", custom.session_id
    assert_equal ["checkout"], custom.tags

    # No new stats for this date
    assert_equal link_stats_before, LinkDailyStatistic.where(event_date: Date.parse("2026-07-03")).count
    assert_equal visitor_stats_before, VisitorDailyStatistic.where(event_date: Date.parse("2026-07-03")).count
  end

  # --- Test 4 ---
  test "view_dedup_within_single_batch" do
    date = "2026-07-04T12:00:00Z"
    3.times { push_event(type: Grovs::Events::VIEW, device: @device, link: @link, created_at: date) }

    assert_difference "Event.count", 1 do
      perform_fast(@job)
    end

    link_stat = LinkDailyStatistic.find_by(project_id: @project.id, link_id: @link.id,
                                           event_date: Date.parse("2026-07-04"),
                                           platform: @device.platform_for_metrics)
    assert_equal 1, link_stat.views

    visitor_stat = VisitorDailyStatistic.find_by(project_id: @project.id, visitor_id: @visitor.id,
                                                 event_date: Date.parse("2026-07-04"),
                                                 platform: @device.platform_for_metrics)
    assert_equal 1, visitor_stat.views
  end

  # --- Test 5 ---
  test "install_with_referral_generates_user_referred" do
    @link.update_column(:visitor_id, @android_visitor.id)

    date = "2026-07-05T12:00:00Z"
    push_event(type: Grovs::Events::INSTALL, device: @device, link: @link, created_at: date)

    assert_difference "Event.count", 2 do
      perform_fast(@job)
    end

    # INSTALL event for the installer
    install = Event.find_by(project_id: @project.id, device_id: @device.id,
                            event: Grovs::Events::INSTALL, created_at: Time.parse(date))
    assert install

    # USER_REFERRED event for the referrer
    referred = Event.find_by(project_id: @project.id, device_id: @android_device.id,
                             event: Grovs::Events::USER_REFERRED, created_at: Time.parse(date))
    assert referred
    assert_equal @android_device.platform, referred.platform

    # inviter_id set on installer's visitor
    @visitor.reload
    assert_equal @android_visitor.id, @visitor.inviter_id

    stat_date = Date.parse("2026-07-05")

    # Installer VisitorDailyStat: installs:1
    installer_stat = VisitorDailyStatistic.find_by(project_id: @project.id, visitor_id: @visitor.id,
                                                   event_date: stat_date,
                                                   platform: @device.platform_for_metrics)
    assert installer_stat
    assert_equal 1, installer_stat.installs

    # Referrer VisitorDailyStat: user_referred:1
    referrer_stat = VisitorDailyStatistic.find_by(project_id: @project.id, visitor_id: @android_visitor.id,
                                                  event_date: stat_date,
                                                  platform: @android_device.platform_for_metrics)
    assert referrer_stat
    assert_equal 1, referrer_stat.user_referred

    # VisitorLastVisit created for installer
    vlv = VisitorLastVisit.find_by(project_id: @project.id, visitor_id: @visitor.id)
    assert vlv, "VisitorLastVisit should be created for the installer"
    assert_equal @link.id, vlv.link_id
  end

  # --- Test 6 ---
  test "time_spent_uses_engagement_time_as_additive_value" do
    date = "2026-07-06T12:00:00Z"
    push_event(type: Grovs::Events::TIME_SPENT, device: @device, created_at: date, engagement_time: 3000)
    push_event(type: Grovs::Events::TIME_SPENT, device: @device, created_at: date, engagement_time: 5000)

    assert_difference "Event.count", 2 do
      perform_fast(@job)
    end

    visitor_stat = VisitorDailyStatistic.find_by(project_id: @project.id, visitor_id: @visitor.id,
                                                 event_date: Date.parse("2026-07-06"),
                                                 platform: @device.platform_for_metrics)
    assert_equal 8000, visitor_stat.time_spent

    # No link stats for linkless events
    link_stat = LinkDailyStatistic.find_by(event_date: Date.parse("2026-07-06"),
                                           platform: @device.platform_for_metrics)
    assert_nil link_stat
  end

  # --- Test 7 ---
  test "stats_additive_across_two_batches" do
    date = "2026-07-07T12:00:00Z"
    stat_date = Date.parse("2026-07-07")
    platform = @device.platform_for_metrics

    # Batch 1: 2 OPENs
    2.times { push_event(type: Grovs::Events::OPEN, device: @device, link: @link, created_at: date) }
    perform_fast(@job)

    # Batch 2: 3 more OPENs with fresh job
    job2 = BatchEventProcessorJob.new
    job2.jid = "pipeline-pg-batch2-#{SecureRandom.hex(4)}"
    @extra_jids << job2.jid
    3.times { push_event(type: Grovs::Events::OPEN, device: @device, link: @link, created_at: date) }
    perform_fast(job2)

    assert_equal 5, Event.where(project_id: @project.id, device_id: @device.id,
                                event: Grovs::Events::OPEN, created_at: Time.parse(date)).count

    link_stat = LinkDailyStatistic.find_by(project_id: @project.id, link_id: @link.id,
                                           event_date: stat_date, platform: platform)
    assert_equal 5, link_stat.opens

    visitor_stat = VisitorDailyStatistic.find_by(project_id: @project.id, visitor_id: @visitor.id,
                                                 event_date: stat_date, platform: platform)
    assert_equal 5, visitor_stat.opens
  end

  # --- Test 8 ---
  test "multi_device_batch_routes_correctly" do
    date = "2026-07-08T12:00:00Z"
    stat_date = Date.parse("2026-07-08")
    other_link = links(:no_custom_redirect_link)

    # ios_device: VIEW + OPEN (basic_link) + TIME_SPENT (no link, 2000ms)
    push_event(type: Grovs::Events::VIEW, device: @device, link: @link, created_at: date)
    push_event(type: Grovs::Events::OPEN, device: @device, link: @link, created_at: date)
    push_event(type: Grovs::Events::TIME_SPENT, device: @device, created_at: date, engagement_time: 2000)

    # android_device: VIEW + INSTALL (no_custom_redirect_link)
    push_event(type: Grovs::Events::VIEW, device: @android_device, link: other_link, created_at: date)
    push_event(type: Grovs::Events::INSTALL, device: @android_device, link: other_link, created_at: date)

    assert_difference "Event.count", 5 do
      perform_fast(@job)
    end

    # ios visitor stats
    ios_stat = VisitorDailyStatistic.find_by(project_id: @project.id, visitor_id: @visitor.id,
                                             event_date: stat_date,
                                             platform: @device.platform_for_metrics)
    assert ios_stat
    assert_equal 1, ios_stat.views
    assert_equal 1, ios_stat.opens
    assert_equal 2000, ios_stat.time_spent

    # android visitor stats
    android_stat = VisitorDailyStatistic.find_by(project_id: @project.id, visitor_id: @android_visitor.id,
                                                 event_date: stat_date,
                                                 platform: @android_device.platform_for_metrics)
    assert android_stat
    assert_equal 1, android_stat.views
    assert_equal 1, android_stat.installs

    # basic_link stats (ios VIEW + OPEN)
    basic_stat = LinkDailyStatistic.find_by(project_id: @project.id, link_id: @link.id,
                                            event_date: stat_date,
                                            platform: @device.platform_for_metrics)
    assert basic_stat
    assert_equal 1, basic_stat.views
    assert_equal 1, basic_stat.opens

    # other_link stats (android VIEW + INSTALL)
    other_stat = LinkDailyStatistic.find_by(project_id: @project.id, link_id: other_link.id,
                                            event_date: stat_date,
                                            platform: @android_device.platform_for_metrics)
    assert other_stat
    assert_equal 1, other_stat.views
    assert_equal 1, other_stat.installs

    # TIME_SPENT with no link should NOT create a link stat
    ts_link_stat = LinkDailyStatistic.find_by(event_date: stat_date,
                                              platform: @device.platform_for_metrics,
                                              link_id: nil)
    assert_nil ts_link_stat
  end

  # --- Test 9 ---
  test "mixed_valid_and_invalid_payloads" do
    date = "2026-07-09T12:00:00Z"
    # Valid OPEN
    push_event(type: Grovs::Events::OPEN, device: @device, created_at: date)
    # Malformed JSON
    REDIS.with { |conn| conn.lpush(BatchEventProcessorJob::REDIS_KEY, "not json {{{") }
    # Missing device_id
    REDIS.with do |conn|
      conn.lpush(BatchEventProcessorJob::REDIS_KEY,
                 { type: Grovs::Events::VIEW, project_id: @project.id, created_at: date }.to_json)
    end
    # Invalid event type
    REDIS.with do |conn|
      conn.lpush(BatchEventProcessorJob::REDIS_KEY,
                 { type: "bogus", project_id: @project.id, device_id: @device.id, created_at: date }.to_json)
    end

    assert_difference "Event.count", 1 do
      perform_fast(@job)
    end

    # Only the valid OPEN survived
    event = Event.find_by(project_id: @project.id, device_id: @device.id,
                          event: Grovs::Events::OPEN, created_at: Time.parse(date))
    assert event, "Only the valid OPEN should survive"

    # Redis drained (invalid payloads discarded, not stuck)
    REDIS.with do |conn|
      assert_equal 0, conn.llen(BatchEventProcessorJob::REDIS_KEY)
    end
  end

  # --- Test 10 ---
  # Uses process_batch directly (not perform) so both batches complete within
  # the real 5s dedup TTL window. This tests genuine cross-batch dedup — the
  # SET NX key from batch 1 survives to block batch 2's VIEW.
  test "cross_batch_view_dedup" do
    date = "2026-07-10T12:00:00Z"
    stat_date = Date.parse("2026-07-10")

    batch1 = [event_json(type: Grovs::Events::VIEW, device: @device, link: @link, created_at: date)]
    @job.send(:process_batch, batch1)

    assert_equal 1, Event.where(project_id: @project.id, device_id: @device.id,
                                event: Grovs::Events::VIEW, link_id: @link.id).count

    # The real 5s dedup key should exist from batch 1's pipeline_view_dedup
    assert REDIS.with { |conn| conn.exists?("events:dedup:#{@project.id}:#{@device.id}:view") },
      "Batch 1 should have set the dedup key via pipeline_view_dedup"

    # Batch 2: runs immediately after (~10ms), well within the 5s dedup window
    job2 = BatchEventProcessorJob.new
    job2.jid = "pipeline-pg-dedup2-#{SecureRandom.hex(4)}"
    @extra_jids << job2.jid
    batch2 = [event_json(type: Grovs::Events::VIEW, device: @device, link: @link, created_at: date)]
    job2.send(:process_batch, batch2)

    # Should still be 1 — the real dedup key blocked batch 2's VIEW
    assert_equal 1, Event.where(project_id: @project.id, device_id: @device.id,
                                event: Grovs::Events::VIEW, link_id: @link.id).count,
      "Cross-batch VIEW dedup should prevent duplicate"

    link_stat = LinkDailyStatistic.find_by(project_id: @project.id, link_id: @link.id,
                                           event_date: stat_date,
                                           platform: @device.platform_for_metrics)
    assert_equal 1, link_stat.views
  end

end
# rubocop:enable Metrics/ClassLength

# =============================================================================
# CH pipeline tests: same Redis → perform() flow, also verifies ClickHouse
# =============================================================================

# rubocop:disable Metrics/ClassLength
class BatchEventProcessorPipelineChTest < ActiveSupport::TestCase
  include ClickhouseTestHelper
  include PipelineTestHelpers

  fixtures :instances, :projects, :devices, :visitors, :links, :domains, :redirect_configs, :events,
           :visitor_daily_statistics, :link_daily_statistics

  setup do
    skip_unless_clickhouse!

    @job = BatchEventProcessorJob.new
    @job.jid = "pipeline-ch-#{SecureRandom.hex(4)}"
    @project = projects(:one)
    @device = devices(:ios_device)
    @android_device = devices(:android_device)
    @visitor = visitors(:ios_visitor)
    @android_visitor = visitors(:android_visitor)
    @link = links(:basic_link)

    REDIS.with do |conn|
      conn.del(BatchEventProcessorJob::REDIS_KEY)
      conn.del("events:dedup:#{@project.id}:#{@device.id}:view")
      conn.del("events:dedup:#{@project.id}:#{@android_device.id}:view")
      # Clear CH batch-done keys left over from prior runs — test data is
      # deterministic so fingerprints repeat, causing inserts to be skipped.
      cursor = "0"
      loop do
        cursor, keys = conn.scan(cursor, match: "#{BatchEventProcessorJob::CH_BATCH_DONE_PREFIX}:*", count: 100)
        conn.del(*keys) if keys.any?
        break if cursor == "0"
      end
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
    end
  end

  # --- Test 11 ---
  test "full_pipeline_pg_and_ch_for_single_open" do
    date = "2026-07-11T12:00:00Z"
    push_event(type: Grovs::Events::OPEN, device: @device, link: @link, created_at: date)

    assert_difference "Event.count", 1 do
      perform_fast(@job)
    end

    # PG stats
    link_stat = LinkDailyStatistic.find_by(project_id: @project.id, link_id: @link.id,
                                           event_date: Date.parse("2026-07-11"),
                                           platform: @device.platform_for_metrics)
    assert link_stat
    assert_equal 1, link_stat.opens

    # CH event
    assert_equal 1, ch_event_count(@project.id, event_type: Grovs::Events::OPEN)

    ch_events = ch_select_events(@project.id,
                                 columns: %w[device_model platform timezone language
                                             tracking_source tracking_campaign
                                             sdk_identifier visitor_id])
    assert_equal 1, ch_events.size
    ch = ch_events.first

    # Device context
    assert_equal @device.model, ch['device_model']
    assert_equal @device.platform, ch['platform']
    assert_equal @device.timezone, ch['timezone']
    assert_equal @device.language, ch['language']

    # Link attribution
    assert_equal @link.tracking_source, ch['tracking_source']
    assert_equal @link.tracking_campaign, ch['tracking_campaign']

    # Visitor context
    assert_equal @visitor.sdk_identifier, ch['sdk_identifier']
    assert_equal @visitor.id, ch['visitor_id']

    # User profile
    profile_count = Clickhouse.with do |conn|
      conn.select_value("SELECT COUNT(*) FROM user_profiles WHERE project_id = #{Integer(@project.id)} AND visitor_id = #{Integer(@visitor.id)}")
    end
    assert_equal 1, profile_count
  end

  # --- Test 12 ---
  test "multi_type_multi_device_pg_ch_parity" do
    date = "2026-07-12T12:00:00Z"
    stat_date = Date.parse("2026-07-12")

    # ios: VIEW, OPEN, CUSTOM (enriched), TIME_SPENT(7500), REACTIVATION = 5 events
    push_event(type: Grovs::Events::VIEW, device: @device, link: @link, created_at: date)
    push_event(type: Grovs::Events::OPEN, device: @device, link: @link, created_at: date)
    push_event(type: Grovs::Events::CUSTOM, device: @device, created_at: date,
               event_name: "checkout", session_id: "sess-12", tags: ["revenue"], data: { "amount" => 99 })
    push_event(type: Grovs::Events::TIME_SPENT, device: @device, created_at: date, engagement_time: 7500)
    push_event(type: Grovs::Events::REACTIVATION, device: @device, link: @link, created_at: date)

    # android: VIEW, OPEN, SCREEN_VIEW = 3 events
    push_event(type: Grovs::Events::VIEW, device: @android_device, link: @link, created_at: date)
    push_event(type: Grovs::Events::OPEN, device: @android_device, link: @link, created_at: date)
    push_event(type: Grovs::Events::SCREEN_VIEW, device: @android_device, created_at: date,
               event_name: "home_screen", session_id: "sess-12-sv", tags: ["nav"])

    assert_difference "Event.count", 8 do
      perform_fast(@job)
    end

    # PG count == CH count
    pg_count = Event.where(project_id: @project.id, created_at: Time.parse(date)).count
    ch_count = ch_event_count(@project.id)
    assert_equal pg_count, ch_count, "PG and CH event counts should match"
    assert_equal 8, ch_count

    # Device context correct per device in CH
    ch_events = ch_select_events(@project.id, columns: %w[device_id device_model platform event_type
                                                           event_name session_id tags])
    ios_ch = ch_events.select { |r| r['device_id'] == @device.id }
    android_ch = ch_events.select { |r| r['device_id'] == @android_device.id }

    assert_equal 5, ios_ch.size
    assert_equal 3, android_ch.size

    ios_ch.each { |r| assert_equal @device.model, r['device_model'] }
    android_ch.each { |r| assert_equal @android_device.model, r['device_model'] }

    # Enrichment fields on CUSTOM
    custom = ios_ch.find { |r| r['event_type'] == Grovs::Events::CUSTOM }
    assert_equal "checkout", custom['event_name']
    assert_equal "sess-12", custom['session_id']
    assert_equal ["revenue"], custom['tags']

    # Enrichment fields on SCREEN_VIEW
    sv = android_ch.find { |r| r['event_type'] == Grovs::Events::SCREEN_VIEW }
    assert_equal "home_screen", sv['event_name']
    assert_equal "sess-12-sv", sv['session_id']
    assert_equal ["nav"], sv['tags']

    # 2 user profiles
    profile_count = Clickhouse.with do |conn|
      conn.select_value("SELECT COUNT(*) FROM user_profiles WHERE project_id = #{Integer(@project.id)}")
    end
    assert_equal 2, profile_count

    # PG stats correct per visitor
    ios_stat = VisitorDailyStatistic.find_by(project_id: @project.id, visitor_id: @visitor.id,
                                             event_date: stat_date,
                                             platform: @device.platform_for_metrics)
    assert ios_stat
    assert_equal 1, ios_stat.views
    assert_equal 1, ios_stat.opens
    assert_equal 7500, ios_stat.time_spent
    assert_equal 1, ios_stat.reactivations

    android_stat = VisitorDailyStatistic.find_by(project_id: @project.id, visitor_id: @android_visitor.id,
                                                 event_date: stat_date,
                                                 platform: @android_device.platform_for_metrics)
    assert android_stat
    assert_equal 1, android_stat.views
    assert_equal 1, android_stat.opens
  end

  # --- Test 13 ---
  test "referral_in_both_pg_and_ch" do
    @link.update_column(:visitor_id, @android_visitor.id)

    date = "2026-07-13T12:00:00Z"
    push_event(type: Grovs::Events::INSTALL, device: @device, link: @link, created_at: date)

    assert_difference "Event.count", 2 do
      perform_fast(@job)
    end

    # CH should have 2 events
    ch_events = ch_select_events(@project.id,
                                 columns: %w[event_type device_id device_model platform visitor_id])
    assert_equal 2, ch_events.size

    install_row = ch_events.find { |r| r['event_type'] == Grovs::Events::INSTALL }
    referred_row = ch_events.find { |r| r['event_type'] == Grovs::Events::USER_REFERRED }

    assert install_row
    assert referred_row

    # USER_REFERRED has referrer's (android) device context
    assert_equal @android_device.id, referred_row['device_id']
    assert_equal @android_device.model, referred_row['device_model']
    assert_equal @android_device.platform, referred_row['platform']

    # 2 user profiles (installer + referrer)
    profile_count = Clickhouse.with do |conn|
      conn.select_value("SELECT COUNT(*) FROM user_profiles WHERE project_id = #{Integer(@project.id)}")
    end
    assert_equal 2, profile_count
  end

  # --- Test 14 ---
  test "old_format_payload_backward_compat" do
    date = "2026-07-14T12:00:00Z"
    # Old SDK payloads lack event_name, session_id, and tags keys entirely.
    # (data/link_id/engagement_time being nil is normal for all events —
    # the distinguishing trait of old-format is the missing enrichment keys.)
    payload = {
      type: Grovs::Events::OPEN,
      project_id: @project.id,
      device_id: @device.id,
      data: nil,
      link_id: nil,
      engagement_time: nil,
      created_at: date
    }
    REDIS.with { |conn| conn.lpush(BatchEventProcessorJob::REDIS_KEY, payload.to_json) }

    assert_difference "Event.count", 1 do
      perform_fast(@job)
    end

    # PG defaults
    pg_event = Event.find_by(project_id: @project.id, device_id: @device.id,
                             event: Grovs::Events::OPEN, created_at: Time.parse(date))
    assert_equal "", pg_event.event_name
    assert_equal "", pg_event.session_id
    assert_equal [], pg_event.tags

    # CH defaults
    ch_events = ch_select_events(@project.id, columns: %w[event_name session_id tags device_model platform])
    assert_equal 1, ch_events.size
    ch = ch_events.first
    assert_equal "", ch['event_name']
    assert_equal "", ch['session_id']
    assert_equal [], ch['tags']

    # Device denormalization still correct
    assert_equal @device.model, ch['device_model']
    assert_equal @device.platform, ch['platform']
  end

  # --- Test 15 ---
  test "view_dedup_reflected_in_ch" do
    date = "2026-07-15T12:00:00Z"
    # 3 ios VIEWs (only 1 survives dedup) + 1 android VIEW + 2 ios OPENs
    3.times { push_event(type: Grovs::Events::VIEW, device: @device, link: @link, created_at: date) }
    push_event(type: Grovs::Events::VIEW, device: @android_device, link: @link, created_at: date)
    # Distinct session_id so the two OPENs are distinct events (identical content
    # would collapse under the ReplacingMergeTree dedup by event_id).
    2.times { |i| push_event(type: Grovs::Events::OPEN, device: @device, link: @link, created_at: date, session_id: "open-#{i}") }

    assert_difference "Event.count", 4 do
      perform_fast(@job)
    end

    # CH should also have exactly 4 events (dedup applied before dual-write).
    # NOTE: we don't re-check PG with a created_at filter because touch_deduped_views
    # rolls the surviving iOS VIEW's created_at forward to Time.current.
    ch_count = ch_event_count(@project.id)
    assert_equal 4, ch_count, "CH should have 4 events after VIEW dedup (1 ios VIEW + 1 android VIEW + 2 OPENs)"

    # VIEWs: 1 ios + 1 android = 2
    ch_views = ch_event_count(@project.id, event_type: Grovs::Events::VIEW)
    assert_equal 2, ch_views, "Deduped ios VIEWs should not appear in CH (1 ios + 1 android = 2)"
  end
end
# rubocop:enable Metrics/ClassLength
