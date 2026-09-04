require "test_helper"

# rubocop:disable Metrics/ClassLength
class BatchEventProcessorJobTest < ActiveSupport::TestCase
  fixtures :instances, :projects, :devices, :visitors, :links, :domains, :redirect_configs, :events,
          :visitor_daily_statistics, :link_daily_statistics, :campaigns

  setup do
    @job = BatchEventProcessorJob.new
    @row_builder = ClickhouseEventRowBuilder.new
    @job.jid = "test-jid-#{SecureRandom.hex(4)}"
    @project = projects(:one)
    @device = devices(:ios_device)
    @visitor = visitors(:ios_visitor)
    @link = links(:basic_link)

    # Redis isn't transactional and is shared across tests within a parallel
    # worker, so keys leak between tests. The orphan-recovery tests SCAN every
    # `events:processing:*` key, so a stray key left by an earlier test would be
    # swept in and inflate Event.count (flaky `assert_difference`). Start and end
    # each test from a clean event-pipeline namespace.
    clear_event_redis_namespace
  end

  teardown do
    clear_event_redis_namespace
  end

  def clear_event_redis_namespace
    REDIS.with do |conn|
      cursor = "0"
      loop do
        cursor, keys = conn.scan(cursor, match: "events:*", count: 1000)
        conn.del(*keys) unless keys.empty?
        break if cursor == "0"
      end
    end
  end

  # --- parse_events ---

  test "parse_events rejects malformed JSON" do
    result = @job.send(:parse_events, ["not json {{{"])
    assert_equal [], result
  end

  test "parse_events rejects missing required fields" do
    incomplete = { type: Grovs::Events::VIEW, project_id: @project.id }.to_json # missing device_id
    result = @job.send(:parse_events, [incomplete])
    assert_equal [], result
  end

  test "parse_events rejects invalid event type" do
    valid = { type: Grovs::Events::VIEW, project_id: @project.id, device_id: @device.id, created_at: Time.current.iso8601 }.to_json
    invalid = { type: "bogus", project_id: @project.id, device_id: @device.id, created_at: Time.current.iso8601 }.to_json

    result = @job.send(:parse_events, [valid, invalid])
    assert_equal 1, result.size
    assert_equal Grovs::Events::VIEW, result.first[:type]
  end

  test "parse_events sets occurred_at from created_at" do
    ts = "2026-03-15T10:30:00Z"
    raw = { type: Grovs::Events::VIEW, project_id: @project.id, device_id: @device.id, created_at: ts }.to_json

    result = @job.send(:parse_events, [raw])
    assert_equal 1, result.size
    assert_in_delta Time.parse(ts), result.first[:occurred_at], 1
  end

  test "parse_events uses current time for invalid timestamp" do
    raw = { type: Grovs::Events::VIEW, project_id: @project.id, device_id: @device.id, created_at: "not-a-time" }.to_json

    result = @job.send(:parse_events, [raw])
    assert_equal 1, result.size
    assert_in_delta Time.current, result.first[:occurred_at], 5
  end

  # --- persist_batch creates correct Event records ---

  test "persist_batch stores Event with device fields and link path" do
    occurred_at = Time.new(2026, 6, 15, 10, 0, 0)
    event_row = @job.send(:build_event_row,
      { type: Grovs::Events::VIEW, project_id: @project.id, device_id: @device.id,
        occurred_at: occurred_at, data: nil, engagement_time: 100 },
      @project, @device, @link
    )

    @job.send(:persist_batch, [event_row], [], Set.new, {}, [], {})

    event = Event.find_by(
      project_id: @project.id, device_id: @device.id,
      event: Grovs::Events::VIEW, link_id: @link.id, created_at: occurred_at
    )
    assert event, "Event should be persisted to DB"
    assert_equal @device.ip, event.ip
    assert_equal @device.remote_ip, event.remote_ip
    assert_equal @device.platform, event.platform
    assert_equal @link.path, event.path
    assert_equal true, event.processed
    assert_equal 100, event.engagement_time
  end

  test "persist_batch refreshes the heartbeat so a long transaction is not treated as orphaned" do
    event_row = @job.send(:build_event_row,
      { type: Grovs::Events::VIEW, project_id: @project.id, device_id: @device.id,
        occurred_at: Time.current, data: nil, engagement_time: 0 },
      @project, @device, @link
    )

    @job.send(:persist_batch, [event_row], [], Set.new, {}, [], {})

    assert REDIS.exists?("events:heartbeat:#{@job.jid}"),
      "persist_batch must refresh the heartbeat — recovery would repush a batch whose transaction still commits"
  end

  # --- build_stats_update ---

  test "build_stats_update uses engagement_time for time_spent" do
    payload = {
      type: Grovs::Events::TIME_SPENT, project_id: @project.id, device_id: @device.id,
      occurred_at: Time.current, engagement_time: 4200
    }

    visitors_index = { [@project.id, @device.id] => @visitor }
    visitor_ids = Set.new

    update = @job.send(:build_stats_update, payload, @project, @device, nil, visitors_index, visitor_ids)
    assert update
    assert_equal 4200, update[:visitor_updates][:stats][:metrics][:time_spent]
  end

  test "build_stats_update returns nil for unmapped event" do
    payload = {
      type: "bogus", project_id: @project.id, device_id: @device.id,
      occurred_at: Time.current
    }

    visitors_index = { [@project.id, @device.id] => @visitor }
    visitor_ids = Set.new

    result = @job.send(:build_stats_update, payload, @project, @device, nil, visitors_index, visitor_ids)
    assert result.nil?, "Expected nil for unmapped event type"
  end

  # --- handle_referrals ---

  test "handle_referrals creates USER_REFERRED for install with link visitor" do
    # Link needs a visitor_id (the referrer)
    referrer_device = devices(:android_device)
    referrer_visitor = visitors(:android_visitor)
    @link.update_column(:visitor_id, referrer_visitor.id)

    parsed = [{
      type: Grovs::Events::INSTALL, project_id: @project.id, device_id: @device.id,
      link_id: @link.id, occurred_at: Time.current
    }]

    projects = { @project.id => @project }
    devices_hash = { @device.id => @device, referrer_device.id => referrer_device }
    links_hash = { @link.id => @link.reload }
    visitors_index = {
      [@project.id, @device.id] => @visitor,
      [@project.id, referrer_device.id] => referrer_visitor
    }

    event_rows, updates, inviter_assignments = @job.send(:handle_referrals, parsed, projects, devices_hash, links_hash, visitors_index)

    assert_equal 1, event_rows.size
    assert_equal Grovs::Events::USER_REFERRED, event_rows.first[:event]
    assert_equal referrer_device.id, event_rows.first[:device_id]
    assert_equal 1, updates.size
    assert_includes inviter_assignments.keys, @visitor.id
  end

  test "handle_referrals skips when no link visitor" do
    # Link with no visitor_id
    @link.update_column(:visitor_id, nil)

    parsed = [{
      type: Grovs::Events::INSTALL, project_id: @project.id, device_id: @device.id,
      link_id: @link.id, occurred_at: Time.current
    }]

    projects = { @project.id => @project }
    devices_hash = { @device.id => @device }
    links_hash = { @link.id => @link.reload }
    visitors_index = { [@project.id, @device.id] => @visitor }

    event_rows, updates, inviter_assignments = @job.send(:handle_referrals, parsed, projects, devices_hash, links_hash, visitors_index)

    assert_empty event_rows
    assert_empty updates
    assert_empty inviter_assignments
  end

  test "handle_referrals does not overwrite existing inviter" do
    referrer_device = devices(:android_device)
    referrer_visitor = visitors(:android_visitor)
    @link.update_column(:visitor_id, referrer_visitor.id)
    @visitor.update_column(:inviter_id, 99999) # already has an inviter

    parsed = [{
      type: Grovs::Events::INSTALL, project_id: @project.id, device_id: @device.id,
      link_id: @link.id, occurred_at: Time.current
    }]

    projects = { @project.id => @project }
    devices_hash = { @device.id => @device, referrer_device.id => referrer_device }
    links_hash = { @link.id => @link.reload }
    visitors_index = {
      [@project.id, @device.id] => @visitor.reload,
      [@project.id, referrer_device.id] => referrer_visitor
    }

    _event_rows, _updates, inviter_assignments = @job.send(:handle_referrals, parsed, projects, devices_hash, links_hash, visitors_index)

    assert_not_includes inviter_assignments.keys, @visitor.id
  end

  test "handle_referrals threads the causal install frozen source into USER_REFERRED ch_meta" do
    referrer_device = devices(:android_device)
    referrer_visitor = visitors(:android_visitor)
    @link.update_column(:visitor_id, referrer_visitor.id)

    parsed = [{
      type: Grovs::Events::INSTALL, project_id: @project.id, device_id: @device.id,
      link_id: @link.id, occurred_at: Time.current,
      event_id: "install-eid", campaign_id: 42, sdk_generated: true, link_visitor_id: 7
    }]
    projects = { @project.id => @project }
    devices_hash = { @device.id => @device, referrer_device.id => referrer_device }
    links_hash = { @link.id => @link.reload }
    visitors_index = {
      [@project.id, @device.id] => @visitor,
      [@project.id, referrer_device.id] => referrer_visitor
    }

    event_rows, = @job.send(:handle_referrals, parsed, projects, devices_hash, links_hash, visitors_index)

    meta = event_rows.first[:ch_meta]
    assert_equal 42, meta[:campaign_id]
    assert_equal true, meta[:sdk_generated]
    assert_equal 7, meta[:link_visitor_id]
    assert_equal Digest::MD5.hexdigest("install-eid:user_referred"), meta[:event_id]
  end

  # --- Phase 1: frozen event-time source capture ---

  test "build_event_row carries frozen ch_meta source from the payload" do
    payload = {
      type: Grovs::Events::OPEN, project_id: @project.id, device_id: @device.id,
      occurred_at: Time.current, data: nil, engagement_time: nil,
      event_id: "frozen-eid", campaign_id: 77, sdk_generated: true, link_visitor_id: 99
    }
    row = @job.send(:build_event_row, payload, @project, @device, @link)

    assert_equal "frozen-eid", row[:ch_meta][:event_id]
    assert_equal 77, row[:ch_meta][:campaign_id]
    assert_equal true, row[:ch_meta][:sdk_generated]
    assert_equal 99, row[:ch_meta][:link_visitor_id]
  end

  test "insert path strips ch_meta before persisting to Postgres" do
    occurred_at = Time.new(2026, 6, 16, 9, 0, 0)
    row = @job.send(:build_event_row,
      { type: Grovs::Events::VIEW, project_id: @project.id, device_id: @device.id,
        occurred_at: occurred_at, data: nil, engagement_time: nil,
        event_id: "x", campaign_id: 1, sdk_generated: false, link_visitor_id: 2 },
      @project, @device, nil)
    assert row.key?(:ch_meta), "row should carry ch_meta"

    assert_difference "Event.count", 1 do
      @job.send(:persist_batch, [row], [], Set.new, {}, [], {})
    end
    assert Event.find_by(project_id: @project.id, device_id: @device.id,
                         event: Grovs::Events::VIEW, created_at: occurred_at)
  end

  test "USER_REFERRED event_id derivation is stable across replays of the causal install" do
    install_payload = {
      type: Grovs::Events::INSTALL, project_id: @project.id, device_id: @device.id,
      event_id: "install-eid", campaign_id: 1, sdk_generated: true, link_visitor_id: 2
    }
    meta_run_1 = EventIngestionService.referral_ch_meta(install_payload)
    meta_run_2 = EventIngestionService.referral_ch_meta(install_payload.dup)
    assert_equal meta_run_1[:event_id], meta_run_2[:event_id], "referral event_id must be replay-stable"
    assert_equal Digest::MD5.hexdigest("install-eid:user_referred"), meta_run_1[:event_id]
  end

  # --- persist_batch ---

  test "persist_batch inserts events and processes stats" do
    occurred_at = Time.current
    event_row = @job.send(:build_event_row,
      { type: Grovs::Events::VIEW, project_id: @project.id, device_id: @device.id, occurred_at: occurred_at, data: nil, engagement_time: nil },
      @project, @device, nil
    )

    assert_difference "Event.count", 1 do
      @job.send(:persist_batch, [event_row], [], Set.new, {}, [], {})
    end
  end

  test "persist_batch upserts visitor_last_visits" do
    parsed = [{
      type: Grovs::Events::VIEW, project_id: @project.id, device_id: @device.id,
      link_id: @link.id, occurred_at: Time.current
    }]
    visitors_index = { [@project.id, @device.id] => @visitor }

    assert_difference "VisitorLastVisit.count" do
      @job.send(:persist_batch, [], [], Set.new, {}, parsed, visitors_index)
    end

    vlv = VisitorLastVisit.find_by(project_id: @project.id, visitor_id: @visitor.id)
    assert_equal @link.id, vlv.link_id
  end

  # --- bulk_upsert_visitor_last_visits ---

  test "bulk_upsert_visitor_last_visits last event wins" do
    other_link = links(:no_custom_redirect_link) # same project as @link (domain: one → project: one)
    parsed = [
      { type: Grovs::Events::VIEW, project_id: @project.id, device_id: @device.id,
        link_id: @link.id, occurred_at: Time.current },
      { type: Grovs::Events::VIEW, project_id: @project.id, device_id: @device.id,
        link_id: other_link.id, occurred_at: Time.current }
    ]
    visitors_index = { [@project.id, @device.id] => @visitor }

    @job.send(:bulk_upsert_visitor_last_visits, parsed, visitors_index)

    vlv = VisitorLastVisit.find_by(project_id: @project.id, visitor_id: @visitor.id)
    assert_equal other_link.id, vlv.link_id, "Last event's link should win"
  end

  # ===========================================================================
  # Redis-backed tests: pop_events, dedup, recovery, perform loop
  #
  # NOTE: Tests run in parallel and share a single Redis instance. We clean
  # our specific keys in both setup and teardown to avoid cross-process
  # contamination. We also use unique jids and avoid scanning/deleting
  # keys that might belong to other test processes.
  # ===========================================================================

  teardown do
    REDIS.with do |conn|
      conn.del(BatchEventProcessorJob::REDIS_KEY)
      conn.del("events:processing:#{@job.jid}")
      conn.del("events:heartbeat:#{@job.jid}")
      # Clean dedup keys for all fixture devices
      conn.del("events:dedup:#{@project.id}:#{@device.id}:view") if @device
      conn.del("events:dedup:#{@project.id}:#{devices(:android_device).id}:view")
    end
  end

  # --- pop_events ---

  test "pop_events atomically moves events from pending to processing" do
    # Test the Lua script directly with a unique key to avoid parallel contention.
    # In production, REDIS_KEY is the shared queue. Here we verify the Lua
    # POP_SCRIPT contract: items move from source → dest atomically.
    temp_pending = "test:pending:#{@job.jid}"
    temp_processing = "test:processing:#{@job.jid}"

    REDIS.with do |conn|
      conn.del(temp_pending, temp_processing)
      conn.lpush(temp_pending, ["ev1", "ev2", "ev3"])
    end

    # Execute the same Lua script that pop_events uses
    result = REDIS.eval(
      BatchEventProcessorJob::POP_SCRIPT,
      keys: [temp_pending, temp_processing],
      argv: [2]
    )
    assert_equal 2, result.size

    # 1 should remain in pending
    assert_equal 1, REDIS.llen(temp_pending)

    # 2 should be in processing
    assert_equal 2, REDIS.llen(temp_processing)

    # Clean up
    REDIS.with { |conn| conn.del(temp_pending, temp_processing) }
  end

  test "pop_events returns empty array when queue is empty" do
    REDIS.del(BatchEventProcessorJob::REDIS_KEY) # Clear from parallel tests
    result = @job.send(:pop_events, 10)
    assert_equal [], result
  end

  test "pop_events returns empty array on Redis error" do
    # NOTE: REDIS.eval here is Redis#eval (Lua script execution), NOT Ruby's Kernel#eval
    broken_redis = Object.new
    broken_redis.define_singleton_method(:call) { |*_| raise Redis::BaseError, "connection refused" }

    REDIS.stub(:eval, ->(*_args) { raise Redis::BaseError, "connection refused" }) do
      result = @job.send(:pop_events, 10)
      assert_equal [], result
    end
  end

  # --- recover_orphaned_events ---

  test "recover_orphaned_events repushes events from dead worker via REPUSH_SCRIPT" do
    # Test the REPUSH_SCRIPT contract directly with unique keys to avoid
    # parallel contention on the shared events:pending queue.
    temp_processing = "test:orphan:processing:#{@job.jid}"
    temp_pending = "test:orphan:pending:#{@job.jid}"

    REDIS.with do |conn|
      conn.del(temp_processing, temp_pending)
      conn.lpush(temp_processing, ["orphan1", "orphan2"])
    end

    # Execute the same Lua script that recover_orphaned_events uses
    count = REDIS.eval(
      BatchEventProcessorJob::REPUSH_SCRIPT,
      keys: [temp_processing, temp_pending]
    )

    assert_equal 2, count

    # Processing key should be deleted
    assert_equal 0, REDIS.llen(temp_processing)

    # Events should be in the pending queue
    pending = REDIS.lrange(temp_pending, 0, -1)
    assert_includes pending, "orphan1"
    assert_includes pending, "orphan2"

    # Clean up
    REDIS.with { |conn| conn.del(temp_processing, temp_pending) }
  end

  test "recover_orphaned_events skips living worker with heartbeat" do
    live_jid = "test-live-#{SecureRandom.hex(4)}"
    live_key = "events:processing:#{live_jid}"

    REDIS.with do |conn|
      conn.lpush(live_key, ["alive1", "alive2"])
      conn.set("events:heartbeat:#{live_jid}", "1", ex: 120) # heartbeat present
    end

    @job.send(:recover_orphaned_events)

    # Events should still be in the processing key
    processing = REDIS.lrange(live_key, 0, -1)
    assert_equal 2, processing.size

    # Clean up
    REDIS.with do |conn|
      conn.del(live_key)
      conn.del("events:heartbeat:#{live_jid}")
    end
  end

  # --- pipeline_view_dedup ---

  test "pipeline_view_dedup skips duplicate VIEWs from same device in batch" do
    # Clear any pre-existing dedup key from parallel tests
    REDIS.del("events:dedup:#{@project.id}:#{@device.id}:view")

    parsed = [
      { type: Grovs::Events::VIEW, device_id: @device.id, project_id: @project.id },
      { type: Grovs::Events::VIEW, device_id: @device.id, project_id: @project.id },
      { type: Grovs::Events::VIEW, device_id: @device.id, project_id: @project.id }
    ]
    devices_hash = { @device.id => @device }

    skip_indices, keys_we_set = @job.send(:pipeline_view_dedup, parsed, devices_hash)

    # First VIEW allowed, 2nd and 3rd skipped
    assert_not_includes skip_indices, 0
    assert_includes skip_indices, 1
    assert_includes skip_indices, 2
    assert_equal 1, keys_we_set.size
  end

  test "pipeline_view_dedup skips all VIEWs when dedup key already exists" do
    # Pre-set dedup key with long TTL (simulating previous batch)
    REDIS.with do |conn|
      conn.set("events:dedup:#{@project.id}:#{@device.id}:view", "1", ex: 60)
    end

    parsed = [
      { type: Grovs::Events::VIEW, device_id: @device.id, project_id: @project.id },
      { type: Grovs::Events::VIEW, device_id: @device.id, project_id: @project.id }
    ]
    devices_hash = { @device.id => @device }

    skip_indices, keys_we_set = @job.send(:pipeline_view_dedup, parsed, devices_hash)

    # ALL VIEWs skipped (cross-batch dedup)
    assert_includes skip_indices, 0
    assert_includes skip_indices, 1
    assert_empty keys_we_set
  end

  test "pipeline_view_dedup returns empty sets when no VIEW events in batch" do
    # Non-VIEW events should be completely ignored by dedup
    parsed = [
      { type: Grovs::Events::OPEN, device_id: @device.id, project_id: @project.id },
      { type: Grovs::Events::INSTALL, device_id: @device.id, project_id: @project.id }
    ]
    devices_hash = { @device.id => @device }

    skip_indices, keys_we_set = @job.send(:pipeline_view_dedup, parsed, devices_hash)
    assert_empty skip_indices
    assert_empty keys_we_set
  end

  test "pipeline_view_dedup does not dedup CUSTOM events from same device" do
    parsed = [
      { type: Grovs::Events::CUSTOM, device_id: @device.id, project_id: @project.id },
      { type: Grovs::Events::CUSTOM, device_id: @device.id, project_id: @project.id },
      { type: Grovs::Events::CUSTOM, device_id: @device.id, project_id: @project.id }
    ]
    devices_hash = { @device.id => @device }

    skip_indices, keys_we_set = @job.send(:pipeline_view_dedup, parsed, devices_hash)
    assert_empty skip_indices, "CUSTOM events must never be deduped"
    assert_empty keys_we_set
  end

  # --- enqueue_if_backlog ---

  test "enqueue_if_backlog enqueues when backlog exceeds one batch" do
    enqueued = false
    REDIS.stub(:llen, BatchEventProcessorJob::BATCH_SIZE + 1) do
      BatchEventProcessorJob.stub(:perform_async, -> { enqueued = true }) do
        @job.send(:enqueue_if_backlog)
      end
    end

    assert enqueued, "Should enqueue follow-up job when backlog exceeds one batch"
  end

  test "enqueue_if_backlog does not enqueue for a sub-batch remainder" do
    enqueued = false
    REDIS.stub(:llen, BatchEventProcessorJob::BATCH_SIZE) do
      BatchEventProcessorJob.stub(:perform_async, -> { enqueued = true }) do
        @job.send(:enqueue_if_backlog)
      end
    end

    assert_not enqueued, "A remainder under one batch is covered by the next cron tick"
  end

  test "enqueue_if_backlog does not enqueue when queue is empty" do
    enqueued = false
    # Mock llen to return 0 (avoids shared Redis queue contention)
    REDIS.stub(:llen, 0) do
      BatchEventProcessorJob.stub(:perform_async, -> { enqueued = true }) do
        @job.send(:enqueue_if_backlog)
      end
    end

    assert_not enqueued, "Should not enqueue when queue is empty"
  end

  # --- full perform ---

  test "perform processes events via process_batch" do
    # Test that process_batch correctly processes events into DB records.
    # Uses process_batch directly to avoid Redis queue contention in parallel tests.
    event_json = {
      type: Grovs::Events::OPEN,
      project_id: @project.id,
      device_id: @device.id,
      data: nil,
      link_id: nil,
      engagement_time: nil,
      created_at: Time.current.iso8601(3)
    }.to_json

    assert_difference "Event.count", 1 do
      @job.send(:process_batch, [event_json])
    end
  end

  test "process_batch stamps device last_seen with the newest event time" do
    older = 10.minutes.ago
    newest = 2.minutes.ago
    payloads = [older, newest].map do |at|
      { type: Grovs::Events::OPEN, project_id: @project.id, device_id: @device.id,
        data: nil, link_id: nil, engagement_time: nil, created_at: at.iso8601(3) }.to_json
    end

    assert_equal :success, @job.send(:process_batch, payloads)

    durable = DeviceLastSeen.find_by!(project_id: @project.id, device_id: @device.id)
    assert_in_delta newest.to_f, durable.last_seen_at.to_f, 0.01
  end

  # ===========================================================================
  # New tests: process_batch integration, error recovery, end-to-end
  # ===========================================================================

  test "process_batch end-to-end creates events and visitor stats" do
    # Use a date that doesn't collide with fixture stats
    event_date = "2026-06-20T12:00:00Z"
    view_json = {
      type: Grovs::Events::VIEW, project_id: @project.id, device_id: @device.id,
      link_id: nil, data: nil, engagement_time: nil, created_at: event_date
    }.to_json
    open_json = {
      type: Grovs::Events::OPEN, project_id: @project.id, device_id: @device.id,
      link_id: nil, data: nil, engagement_time: nil, created_at: event_date
    }.to_json

    assert_difference "Event.count", 2 do
      @job.send(:process_batch, [view_json, open_json])
    end

    stat = VisitorDailyStatistic.find_by(
      project_id: @project.id, visitor_id: @visitor.id,
      event_date: Date.parse("2026-06-20"), platform: @device.platform_for_metrics
    )
    assert stat, "VisitorDailyStatistic should be created"
    assert_equal 1, stat.views
    assert_equal 1, stat.opens
  end

  test "process_batch with link generates link stats" do
    event_date = "2026-06-21T12:00:00Z"
    open_json = {
      type: Grovs::Events::OPEN, project_id: @project.id, device_id: @device.id,
      link_id: @link.id, data: nil, engagement_time: nil, created_at: event_date
    }.to_json

    @job.send(:process_batch, [open_json])

    stat = LinkDailyStatistic.find_by(
      project_id: @project.id, link_id: @link.id,
      event_date: Date.parse("2026-06-21"), platform: @device.platform_for_metrics
    )
    assert stat, "LinkDailyStatistic should be created"
    assert_equal 1, stat.opens
  end

  test "build_stats_update includes link_updates when link is present" do
    payload = {
      type: Grovs::Events::OPEN, project_id: @project.id, device_id: @device.id,
      occurred_at: Time.current, engagement_time: nil
    }
    visitors_index = { [@project.id, @device.id] => @visitor }
    visitor_ids = Set.new

    update = @job.send(:build_stats_update, payload, @project, @device, @link, visitors_index, visitor_ids)
    assert update
    assert update[:link_updates], "link_updates should be present when link is given"
    assert_equal @link.id, update[:link_updates][:link_id]
    assert_equal @project.id, update[:link_updates][:project_id]
    assert_equal({ opens: 1 }, update[:link_updates][:metrics])
  end

  test "process_batch cleans up Redis processing key on success" do
    event_json = {
      type: Grovs::Events::OPEN, project_id: @project.id, device_id: @device.id,
      data: nil, link_id: nil, engagement_time: nil, created_at: Time.current.iso8601(3)
    }.to_json

    # Simulate pop_events having moved data into the processing key
    REDIS.with { |conn| conn.lpush("events:processing:#{@job.jid}", event_json) }

    @job.send(:process_batch, [event_json])

    REDIS.with do |conn|
      assert_equal 0, conn.llen("events:processing:#{@job.jid}"),
        "Processing key should be deleted after successful batch"
    end
  end

  test "process_batch repushes events on DB error" do
    event_json = {
      type: Grovs::Events::OPEN, project_id: @project.id, device_id: @device.id,
      data: nil, link_id: nil, engagement_time: nil, created_at: Time.current.iso8601(3)
    }.to_json

    # Put events in the processing key (as pop_events would)
    REDIS.with { |conn| conn.lpush("events:processing:#{@job.jid}", event_json) }

    # Stub insert_event_rows to raise a statement timeout
    error_msg = "PG::QueryCanceled: ERROR: canceling statement due to statement timeout"
    @job.stub(:insert_event_rows, ->(_rows) { raise ActiveRecord::QueryCanceled, error_msg }) do
      result = @job.send(:process_batch, [event_json])
      assert_equal :failure, result, "process_batch should return :failure on DB error"
    end

    # Events should be back in the pending queue
    REDIS.with do |conn|
      pending = conn.lrange(BatchEventProcessorJob::REDIS_KEY, 0, -1)
      assert_includes pending, event_json, "Events should be repushed to pending"
    end
  end

  test "process_batch cleans up dedup keys on failure" do
    dedup_key = "events:dedup:#{@project.id}:#{@device.id}:view"
    REDIS.with { |conn| conn.del(dedup_key) }

    event_json = {
      type: Grovs::Events::VIEW, project_id: @project.id, device_id: @device.id,
      data: nil, link_id: nil, engagement_time: nil, created_at: Time.current.iso8601(3)
    }.to_json

    REDIS.with { |conn| conn.lpush("events:processing:#{@job.jid}", event_json) }

    # Stub insert_event_rows to raise after dedup keys are set
    @job.stub(:insert_event_rows, ->(_rows) { raise ActiveRecord::QueryCanceled, "PG::QueryCanceled: ERROR: statement timeout" }) do
      @job.send(:process_batch, [event_json])
    end

    # The dedup key we set should have been cleaned up
    assert_equal false, REDIS.with { |conn| conn.exists?(dedup_key) },
      "Dedup key should be cleaned up on batch failure"
  end

  # --- ClickHouse-primary ack durability ---

  def primary_event_json
    { type: Grovs::Events::OPEN, project_id: @project.id, device_id: @device.id,
      data: nil, link_id: nil, engagement_time: nil, created_at: Time.current.iso8601(3) }.to_json
  end

  test "process_batch acks after PG persists when ClickHouse is primary and CH succeeds" do
    event_json = primary_event_json
    REDIS.with { |conn| conn.lpush("events:processing:#{@job.jid}", event_json) }

    Clickhouse.stub(:enabled?, true) do
      Clickhouse.stub(:primary?, true) do
        @job.stub(:dual_write_clickhouse, ->(*) { true }) do
          assert_equal :success, @job.send(:process_batch, [event_json])
        end
      end
    end

    assert_equal 0, REDIS.with { |c| c.llen("events:processing:#{@job.jid}") },
      "processing key must be acked once the PG transaction commits"
  end

  test "process_batch acks and does NOT repush when ClickHouse is primary and CH delivery fails" do
    event_json = primary_event_json
    REDIS.with do |conn| 
      conn.del(BatchEventProcessorJob::REDIS_KEY)
      conn.lpush("events:processing:#{@job.jid}", event_json)
    end

    Clickhouse.stub(:enabled?, true) do
      Clickhouse.stub(:primary?, true) do
        @job.stub(:dual_write_clickhouse, ->(*) { false }) do
          assert_equal :success, @job.send(:process_batch, [event_json])
        end
      end
    end

    # A failed CH write is durably parked in the canonical DLQ by deliver_canonical, so the
    # PG-committed batch must be acked, NOT repushed. Repushing would replay persist_batch and
    # double-insert the PG events / double-count the additive stat upserts (PG has no dedup key).
    pending = REDIS.with { |c| c.lrange(BatchEventProcessorJob::REDIS_KEY, 0, -1) }
    assert_not_includes pending, event_json, "PG-committed batch must not be repushed on CH failure"
    assert_equal 0, REDIS.with { |c| c.llen("events:processing:#{@job.jid}") },
      "processing key must be acked once PG persists (CH durability is the DLQ's job)"
  end

  test "process_batch acks after PG when ClickHouse is not primary even if CH delivery fails" do
    event_json = primary_event_json
    REDIS.with { |conn| conn.lpush("events:processing:#{@job.jid}", event_json) }

    Clickhouse.stub(:enabled?, true) do
      Clickhouse.stub(:primary?, false) do
        @job.stub(:dual_write_clickhouse, ->(*) { false }) do
          assert_equal :success, @job.send(:process_batch, [event_json])
        end
      end
    end

    assert_equal 0, REDIS.with { |c| c.llen("events:processing:#{@job.jid}") },
      "with PG as source of truth the ack is independent of CH delivery"
  end

  test "insert_event_rows recovers from FK violation" do
    occurred_at = Time.current
    bad_project_id = -999
    good_row = @job.send(:build_event_row,
      { type: Grovs::Events::VIEW, project_id: @project.id, device_id: @device.id,
        occurred_at: occurred_at, data: nil, engagement_time: nil },
      @project, @device, nil
    )
    bad_row = good_row.dup.merge(project_id: bad_project_id)

    rows = [bad_row, good_row]
    call_count = 0

    # First insert_all raises InvalidForeignKey, second succeeds with filtered rows
    original_insert_all = Event.method(:insert_all)
    fake_insert_all = lambda { |event_rows, **kwargs|
      call_count += 1
      if call_count == 1
        raise ActiveRecord::InvalidForeignKey, "PG::ForeignKeyViolation: insert or update on table \"events\" violates foreign key constraint"
      end
      original_insert_all.call(event_rows, **kwargs)
    }

    Event.stub(:insert_all, fake_insert_all) do
      assert_difference "Event.count", 1 do
        @job.send(:insert_event_rows, rows)
      end
    end

    assert_equal 2, call_count, "insert_all should be called twice (initial + retry)"
    # Bad row should have been filtered out — only good_row's project remains
    assert Event.exists?(project_id: @project.id, device_id: @device.id, event: Grovs::Events::VIEW, created_at: occurred_at)
  end

  test "build_event_records respects dedup_skip_indices" do
    parsed = [
      { type: Grovs::Events::VIEW, project_id: @project.id, device_id: @device.id,
        occurred_at: Time.current, data: nil, engagement_time: nil, link_id: nil },
      { type: Grovs::Events::OPEN, project_id: @project.id, device_id: @device.id,
        occurred_at: Time.current, data: nil, engagement_time: nil, link_id: nil }
    ]

    projects = { @project.id => @project }
    devices_hash = { @device.id => @device }
    links_hash = {}
    visitors_index = { [@project.id, @device.id] => @visitor }
    dedup_skip_indices = Set.new([0]) # Skip the VIEW at index 0

    event_rows, updates, _visitor_ids, dedup_device_ids =
      @job.send(:build_event_records, parsed, projects, devices_hash, links_hash, visitors_index, dedup_skip_indices)

    # Only the OPEN (index 1) should produce an event row
    assert_equal 1, event_rows.size
    assert_equal Grovs::Events::OPEN, event_rows.first[:event]

    # Only the OPEN should produce a stats update (VIEW was deduped)
    assert_equal 1, updates.size
    assert_equal({ opens: 1 }, updates.first[:visitor_updates][:stats][:metrics])

    # The skipped VIEW's (project, device) pair should be in dedup_device_ids
    assert_includes dedup_device_ids, [@project.id, @device.id]
  end

  test "touch_deduped_views updates created_at on recent VIEWs" do
    # Create a VIEW event within the 10-second window
    recent_view = Event.create!(
      project_id: @project.id, device_id: @device.id,
      event: Grovs::Events::VIEW, platform: @device.platform,
      created_at: 3.seconds.ago, processed: true
    )
    original_time = recent_view.created_at

    @job.send(:touch_deduped_views, Set.new([[@project.id, @device.id]]))

    recent_view.reload
    assert_operator recent_view.created_at, :>, original_time,
      "created_at should be updated to a more recent time"
  end

  test "touch_deduped_views only touches VIEWs in the deduped project" do
    other_project = projects(:two)
    same_project_view = Event.create!(
      project_id: @project.id, device_id: @device.id,
      event: Grovs::Events::VIEW, platform: @device.platform,
      created_at: 3.seconds.ago, processed: true
    )
    other_project_view = Event.create!(
      project_id: other_project.id, device_id: @device.id,
      event: Grovs::Events::VIEW, platform: @device.platform,
      created_at: 3.seconds.ago, processed: true
    )
    other_time = other_project_view.created_at

    @job.send(:touch_deduped_views, Set.new([[@project.id, @device.id]]))

    assert_operator same_project_view.reload.created_at, :>, 3.seconds.ago.advance(seconds: 1),
      "deduped project's VIEW should roll forward"
    assert_in_delta other_time.to_f, other_project_view.reload.created_at.to_f, 0.001,
      "a dedup on one project must not rewrite the same device's VIEW timestamps on another project"
  end

  test "perform deletes heartbeat on completion" do
    # Stub pop_events to return empty immediately so perform exits quickly
    @job.stub(:pop_events, ->(_count) { [] }) do
      @job.stub(:enqueue_if_backlog, nil) do
        @job.perform
      end
    end

    exists = REDIS.with { |conn| conn.exists?("events:heartbeat:#{@job.jid}") }
    assert_equal false, exists, "Heartbeat key should be deleted after perform completes"
  end

  test "perform breaks loop when batch exceeds wall clock limit" do
    batches_processed = 0
    batch_completed = false

    # After process_batch runs, make the elapsed time check exceed the limit
    slow_process = lambda { |_raw_events|
      batches_processed += 1
      batch_completed = true
      true
    }

    pop_count = 0
    fake_pop = lambda { |_count|
      pop_count += 1
      pop_count <= 2 ? ["{}"] : []
    }

    # Time.current jumps forward ONLY after process_batch has completed,
    # so the batch_elapsed check in perform sees > BATCH_WALL_CLOCK_LIMIT.
    # This avoids coupling to the exact number of Time.current calls.
    anchor = Time.current
    fake_time = lambda {
      if batch_completed
        anchor + BatchEventProcessorJob::BATCH_WALL_CLOCK_LIMIT + 10
      else
        anchor
      end
    }

    @job.stub(:pop_events, fake_pop) do
      @job.stub(:process_batch, slow_process) do
        @job.stub(:enqueue_if_backlog, nil) do
          Time.stub(:current, fake_time) do
            @job.perform
          end
        end
      end
    end

    assert_equal 1, batches_processed, "Should only process one batch before breaking due to wall clock limit"
  end

  test "process_batch handles all-malformed batch gracefully" do
    REDIS.with { |conn| conn.lpush("events:processing:#{@job.jid}", "bad json") }

    assert_no_difference "Event.count" do
      result = @job.send(:process_batch, ["not json {{{", "also bad |||", "{incomplete"])
      assert_equal :success, result, "Should return :success for empty parsed batch"
    end

    # Processing key should be cleaned up
    REDIS.with do |conn|
      assert_equal 0, conn.llen("events:processing:#{@job.jid}")
    end
  end

  test "end-to-end via Redis queue" do
    event_date = "2026-06-22T12:00:00Z"
    event_json = {
      type: Grovs::Events::OPEN, project_id: @project.id, device_id: @device.id,
      data: nil, link_id: nil, engagement_time: nil, created_at: event_date
    }.to_json

    # Push into the real Redis pending queue
    REDIS.with { |conn| conn.lpush(BatchEventProcessorJob::REDIS_KEY, event_json) }

    assert_difference "Event.count", 1 do
      @job.perform
    end

    # Verify event record
    event = Event.find_by(
      project_id: @project.id, device_id: @device.id,
      event: Grovs::Events::OPEN, created_at: Time.parse(event_date)
    )
    assert event, "Event should be persisted from Redis queue"

    # Redis queue should be drained
    REDIS.with do |conn|
      assert_equal 0, conn.llen(BatchEventProcessorJob::REDIS_KEY),
        "Pending queue should be empty"
      assert_equal 0, conn.llen("events:processing:#{@job.jid}"),
        "Processing key should be cleaned up"
    end
  end

  test "perform exits loop after consecutive failures" do
    event_json = {
      type: Grovs::Events::OPEN,
      project_id: @project.id,
      device_id: @device.id,
      data: nil,
      link_id: nil,
      engagement_time: nil,
      created_at: Time.current.iso8601(3)
    }.to_json

    failure_count = 0

    # Mock pop_events to always return events (avoids shared Redis queue contention)
    fake_pop = ->(_count) { [event_json] }

    fake_process_batch = lambda { |_raw_events|
      failure_count += 1
      false
    }

    @job.stub(:sleep, nil) do
      @job.stub(:pop_events, fake_pop) do
        @job.stub(:process_batch, fake_process_batch) do
          @job.stub(:enqueue_if_backlog, nil) do
            @job.perform
          end
        end
      end
    end

    # Should have stopped after MAX_CONSECUTIVE_FAILURES (3)
    assert_equal BatchEventProcessorJob::MAX_CONSECUTIVE_FAILURES, failure_count
  end

  # ===========================================================================
  # Critical integration tests: stat correctness, engagement values, referrals
  # ===========================================================================

  test "stats are additive across two batches for the same date" do
    event_date = "2026-07-10T14:00:00Z"
    stat_date = Date.parse("2026-07-10")
    platform = @device.platform_for_metrics
    make_open = lambda {
      { type: Grovs::Events::OPEN, project_id: @project.id, device_id: @device.id,
        link_id: @link.id, data: nil, engagement_time: nil, created_at: event_date }.to_json
    }

    stat_query = lambda {
      LinkDailyStatistic.find_by(
        project_id: @project.id, link_id: @link.id,
        event_date: stat_date, platform: platform
      )
    }

    # First batch: 1 OPEN
    @job.send(:process_batch, [make_open.call])
    assert_equal 1, stat_query.call.opens

    # Second batch: 2 more OPENs — should add, not overwrite
    @job2 = BatchEventProcessorJob.new
    @job2.jid = "test-jid-additive-#{SecureRandom.hex(4)}"
    @job2.send(:process_batch, [make_open.call, make_open.call])

    assert_equal 3, stat_query.call.opens, "Link stats must be additive (1 + 2 = 3), not overwritten"

    vstat = VisitorDailyStatistic.find_by(
      project_id: @project.id, visitor_id: @visitor.id,
      event_date: stat_date, platform: platform
    )
    assert_equal 3, vstat.opens, "Visitor stats must also be additive"

    # Cleanup second job's Redis keys
    REDIS.with do |conn|
      conn.del("events:processing:#{@job2.jid}")
      conn.del("events:heartbeat:#{@job2.jid}")
    end
  end

  test "TIME_SPENT event flows engagement_time value to visitor stats, not 1" do
    event_date = "2026-07-11T14:00:00Z"
    event_json = {
      type: Grovs::Events::TIME_SPENT, project_id: @project.id, device_id: @device.id,
      link_id: nil, data: nil, engagement_time: 7500, created_at: event_date
    }.to_json

    @job.send(:process_batch, [event_json])

    stat = VisitorDailyStatistic.find_by(
      project_id: @project.id, visitor_id: @visitor.id,
      event_date: Date.parse("2026-07-11"), platform: @device.platform_for_metrics
    )
    assert stat, "VisitorDailyStatistic should be created for TIME_SPENT"
    assert_equal 7500, stat.time_spent,
      "time_spent should be the engagement_time value (7500), not 1"
  end

  test "process_batch creates USER_REFERRED event for INSTALL with referral link" do
    referrer_device = devices(:android_device)
    referrer_visitor = visitors(:android_visitor)
    @link.update_column(:visitor_id, referrer_visitor.id)

    event_date = "2026-07-12T14:00:00Z"
    install_json = {
      type: Grovs::Events::INSTALL, project_id: @project.id, device_id: @device.id,
      link_id: @link.id, data: nil, engagement_time: nil, created_at: event_date
    }.to_json

    events_before = Event.count

    @job.send(:process_batch, [install_json])

    # Should create 2 events: the INSTALL + a USER_REFERRED for the referrer
    assert_equal events_before + 2, Event.count

    install_event = Event.find_by(
      project_id: @project.id, device_id: @device.id,
      event: Grovs::Events::INSTALL, created_at: Time.parse(event_date)
    )
    assert install_event, "INSTALL event should be created for the installer"

    referred_event = Event.find_by(
      project_id: @project.id, device_id: referrer_device.id,
      event: Grovs::Events::USER_REFERRED, created_at: Time.parse(event_date)
    )
    assert referred_event, "USER_REFERRED event should be created for the referrer"
    assert_equal referrer_device.platform, referred_event.platform

    # Installer's visitor should have inviter_id set to the referrer visitor
    @visitor.reload
    assert_equal referrer_visitor.id, @visitor.inviter_id,
      "Installer visitor should have inviter_id set to the referrer"
  end
  # ===========================================================================
  # Crash recovery integration: worker A dies, worker B recovers its events
  # ===========================================================================

  test "recover_orphaned_events moves dead worker events to pending, then process_batch persists them" do
    # Worker A popped events into its processing key, then died (no heartbeat).
    dead_jid = "dead-worker-#{SecureRandom.hex(4)}"
    dead_processing_key = "#{BatchEventProcessorJob::PROCESSING_KEY_PREFIX}:#{dead_jid}"

    event_date = "2026-08-01T12:00:00Z"
    orphaned_event = {
      type: Grovs::Events::OPEN, project_id: @project.id, device_id: @device.id,
      data: nil, link_id: nil, engagement_time: nil, created_at: event_date
    }.to_json

    REDIS.with do |conn|
      # Simulate dead worker's state: events in processing, no heartbeat
      conn.lpush(dead_processing_key, orphaned_event)
      conn.del("#{BatchEventProcessorJob::HEARTBEAT_PREFIX}:#{dead_jid}")
    end

    # Worker B calls recover_orphaned_events (as perform does on startup).
    # This moves orphaned events back to the pending queue.
    worker_b = BatchEventProcessorJob.new
    worker_b.jid = "worker-b-#{SecureRandom.hex(4)}"
    worker_b.send(:recover_orphaned_events)

    # Dead worker's processing key should be gone
    REDIS.with do |conn|
      assert_equal false, conn.exists?(dead_processing_key),
        "Dead worker's processing key should be cleaned up by recovery"
    end

    # Events should now be in the pending queue
    REDIS.with do |conn|
      pending = conn.lrange(BatchEventProcessorJob::REDIS_KEY, 0, -1)
      assert_includes pending, orphaned_event,
        "Orphaned event should be moved back to pending"
    end

    # Worker B pops the recovered event and processes it
    raw_events = worker_b.send(:pop_events, BatchEventProcessorJob::BATCH_SIZE)
    assert raw_events.include?(orphaned_event), "Worker B should pop the recovered event"

    assert_difference "Event.count", 1 do
      result = worker_b.send(:process_batch, raw_events)
      assert_equal :success, result, "process_batch should succeed"
    end

    # Verify the event made it to DB with correct attributes
    event = Event.find_by(
      project_id: @project.id, device_id: @device.id,
      event: Grovs::Events::OPEN, created_at: Time.parse(event_date)
    )
    assert event, "Orphaned event should be recovered and persisted to DB"
    assert_equal @device.platform, event.platform
    assert_equal @device.ip, event.ip

    # Cleanup
    REDIS.with do |conn|
      conn.del("events:processing:#{worker_b.jid}")
      conn.del("events:heartbeat:#{worker_b.jid}")
    end
  end

  test "recover_orphaned_events handles multiple dead workers in one pass" do
    dead_jids = 3.times.map { "dead-multi-#{SecureRandom.hex(4)}" }
    event_date = "2026-08-02T12:00:00Z"
    all_events = []

    # Each dead worker left one event in its processing key
    dead_jids.each_with_index do |jid, i|
      processing_key = "#{BatchEventProcessorJob::PROCESSING_KEY_PREFIX}:#{jid}"
      event_json = {
        type: Grovs::Events::OPEN, project_id: @project.id, device_id: @device.id,
        data: nil, link_id: nil, engagement_time: nil,
        created_at: (Time.parse(event_date) + i).iso8601(3)
      }.to_json
      all_events << event_json

      REDIS.with do |conn|
        conn.lpush(processing_key, event_json)
        conn.del("#{BatchEventProcessorJob::HEARTBEAT_PREFIX}:#{jid}")
      end
    end

    worker_b = BatchEventProcessorJob.new
    worker_b.jid = "worker-b-multi-#{SecureRandom.hex(4)}"
    worker_b.send(:recover_orphaned_events)

    # All dead workers' processing keys should be cleaned up
    dead_jids.each do |jid|
      key = "#{BatchEventProcessorJob::PROCESSING_KEY_PREFIX}:#{jid}"
      REDIS.with do |conn|
        assert_equal false, conn.exists?(key),
          "Processing key for dead worker #{jid} should be cleaned up"
      end
    end

    # All 3 events should be in the pending queue
    REDIS.with do |conn|
      pending = conn.lrange(BatchEventProcessorJob::REDIS_KEY, 0, -1)
      all_events.each do |ev|
        assert_includes pending, ev, "Each orphaned event should be in the pending queue"
      end
    end

    # Pop and process — all 3 events should make it to DB
    raw_events = worker_b.send(:pop_events, BatchEventProcessorJob::BATCH_SIZE)

    assert_difference "Event.count", 3 do
      worker_b.send(:process_batch, raw_events)
    end

    # Cleanup
    REDIS.with do |conn|
      conn.del("events:processing:#{worker_b.jid}")
      conn.del("events:heartbeat:#{worker_b.jid}")
    end
  end

  # ===========================================================================
  # ensure_hash — used by CH dual-write for JSON columns
  # ===========================================================================

  # ===========================================================================
  # Event enrichment: event_name, session_id, tags flow through pipeline
  # ===========================================================================

  test "process_batch persists event_name, session_id, tags to PG" do
    event_json = {
      type: Grovs::Events::CUSTOM, project_id: @project.id, device_id: @device.id,
      data: { "screen" => "cart" }, link_id: nil, engagement_time: nil,
      created_at: Time.current.iso8601(3),
      event_name: "add_to_cart", session_id: "sess-abc", tags: ["checkout", "promo"]
    }.to_json

    assert_difference "Event.count", 1 do
      @job.send(:process_batch, [event_json])
    end

    event = Event.order(id: :desc).first
    assert_equal Grovs::Events::CUSTOM, event.event
    assert_equal "add_to_cart", event.event_name
    assert_equal "sess-abc", event.session_id
    assert_equal ["checkout", "promo"], event.tags
    assert_equal({ "screen" => "cart" }, event.data)
  end

  test "process_batch persists SCREEN_VIEW event type with event_name" do
    event_json = {
      type: Grovs::Events::SCREEN_VIEW, project_id: @project.id, device_id: @device.id,
      data: nil, link_id: nil, engagement_time: nil,
      created_at: Time.current.iso8601(3),
      event_name: "screen_view", session_id: "sess-sv", tags: []
    }.to_json

    assert_difference "Event.count", 1 do
      @job.send(:process_batch, [event_json])
    end

    event = Event.order(id: :desc).first
    assert_equal Grovs::Events::SCREEN_VIEW, event.event
    assert_equal "screen_view", event.event_name
    assert_equal "sess-sv", event.session_id
  end

  test "process_batch handles old-format payload without enrichment fields" do
    # Simulates a Redis payload from before this deploy — no event_name/session_id/tags keys
    event_json = {
      type: Grovs::Events::OPEN, project_id: @project.id, device_id: @device.id,
      data: nil, link_id: nil, engagement_time: nil,
      created_at: Time.current.iso8601(3)
    }.to_json

    assert_difference "Event.count", 1 do
      @job.send(:process_batch, [event_json])
    end

    event = Event.order(id: :desc).first
    assert_equal Grovs::Events::OPEN, event.event
    assert_equal "", event.event_name
    assert_equal "", event.session_id
    assert_equal [], event.tags
  end

  test "build_event_row includes enrichment fields from payload" do
    payload = {
      type: Grovs::Events::CUSTOM, project_id: @project.id, device_id: @device.id,
      occurred_at: Time.current, data: nil, engagement_time: nil,
      event_name: "purchase", session_id: "sess-999", tags: ["revenue"]
    }

    row = @job.send(:build_event_row, payload, @project, @device, nil)
    assert_equal "purchase", row[:event_name]
    assert_equal "sess-999", row[:session_id]
    assert_equal ["revenue"], row[:tags]
  end

  test "build_event_row defaults enrichment fields when missing from payload" do
    payload = {
      type: Grovs::Events::VIEW, project_id: @project.id, device_id: @device.id,
      occurred_at: Time.current, data: nil, engagement_time: nil
    }

    row = @job.send(:build_event_row, payload, @project, @device, nil)
    assert_equal "", row[:event_name]
    assert_equal "", row[:session_id]
    assert_equal [], row[:tags]
  end

  # ===========================================================================
  # PG stats gap: CUSTOM and SCREEN_VIEW are NOT in Grovs::Events::MAPPING,
  # so they produce PG Event rows but NO LinkDailyStatistic or
  # VisitorDailyStatistic rows. CH gets the full event with attribution data.
  # This is intentional — custom events shouldn't inflate view/open/install
  # counters — but means CH aggregates will include events that PG stats don't.
  # ===========================================================================

  test "CUSTOM events produce no PG stats (not in MAPPING)" do
    assert_nil Grovs::Events::MAPPING[Grovs::Events::CUSTOM],
      "CUSTOM should not be in MAPPING — no PG stat column for it"

    event_date = "2026-08-10T12:00:00Z"
    event_json = {
      type: Grovs::Events::CUSTOM, project_id: @project.id, device_id: @device.id,
      link_id: @link.id, data: nil, engagement_time: nil, created_at: event_date,
      event_name: "add_to_cart", session_id: "sess-1", tags: []
    }.to_json

    link_stats_before = LinkDailyStatistic.count
    visitor_stats_before = VisitorDailyStatistic.count

    assert_difference "Event.count", 1 do
      @job.send(:process_batch, [event_json])
    end

    assert_equal link_stats_before, LinkDailyStatistic.count,
      "CUSTOM events must not create LinkDailyStatistic rows"
    assert_equal visitor_stats_before, VisitorDailyStatistic.count,
      "CUSTOM events must not create VisitorDailyStatistic rows"
  end

  test "SCREEN_VIEW events produce no PG stats (not in MAPPING)" do
    assert_nil Grovs::Events::MAPPING[Grovs::Events::SCREEN_VIEW],
      "SCREEN_VIEW should not be in MAPPING — no PG stat column for it"

    event_date = "2026-08-11T12:00:00Z"
    event_json = {
      type: Grovs::Events::SCREEN_VIEW, project_id: @project.id, device_id: @device.id,
      link_id: @link.id, data: nil, engagement_time: nil, created_at: event_date,
      event_name: "screen_view", session_id: "sess-2", tags: []
    }.to_json

    link_stats_before = LinkDailyStatistic.count
    visitor_stats_before = VisitorDailyStatistic.count

    assert_difference "Event.count", 1 do
      @job.send(:process_batch, [event_json])
    end

    assert_equal link_stats_before, LinkDailyStatistic.count,
      "SCREEN_VIEW events must not create LinkDailyStatistic rows"
    assert_equal visitor_stats_before, VisitorDailyStatistic.count,
      "SCREEN_VIEW events must not create VisitorDailyStatistic rows"
  end

  # --- bulk_upsert_visitor_last_visits FK-violation fallback ---

  test "bulk_upsert_visitor_last_visits falls back to per-row when a visitor was deleted mid-batch" do
    VisitorLastVisit.where(project_id: @project.id).delete_all
    ghost_id = 2_000_000_001 # no visitors row with this id -> FK violation in bulk upsert

    parsed = [
      { project_id: @project.id, device_id: @device.id, link_id: @link.id },
      { project_id: @project.id, device_id: -1,          link_id: @link.id }
    ]
    visitors_index = {
      [@project.id, @device.id] => @visitor,
      [@project.id, -1]         => Visitor.new.tap { |v| v.id = ghost_id }
    }

    # The bulk upsert_all hits the ghost FK and aborts atomically; the rescue must
    # retry per-row so the valid visitor's last-visit still lands and the ghost is skipped.
    assert_nothing_raised do
      @job.send(:bulk_upsert_visitor_last_visits, parsed, visitors_index)
    end

    vlv = VisitorLastVisit.find_by(project_id: @project.id, visitor_id: @visitor.id)
    assert vlv, "valid visitor's last-visit must survive the per-row fallback"
    assert_equal @link.id, vlv.link_id
    assert_not VisitorLastVisit.exists?(visitor_id: ghost_id),
      "FK-invalid (deleted) visitor must be skipped, not crash the batch"
  end

  # --- remap_merged_devices!: post-merge attribution correctness ---

  test "remap_merged_devices! rewrites device_id from the merge breadcrumb" do
    REDIS.set("#{BatchEventProcessorJob::MERGED_DEVICE_PREFIX}:#{@project.id}:#{@device.id}", 777)
    parsed = [{ project_id: @project.id, device_id: @device.id, link_id: nil }]

    @job.send(:remap_merged_devices!, parsed)

    assert_equal 777, parsed[0][:device_id], "events for a merged device must remap to the target device"
  end

  test "remap_merged_devices! follows a chain of merges to the final device" do
    REDIS.set("#{BatchEventProcessorJob::MERGED_DEVICE_PREFIX}:#{@project.id}:#{@device.id}", 777)
    REDIS.set("#{BatchEventProcessorJob::MERGED_DEVICE_PREFIX}:#{@project.id}:777", 888)
    parsed = [{ project_id: @project.id, device_id: @device.id, link_id: nil }]

    @job.send(:remap_merged_devices!, parsed)

    assert_equal 888, parsed[0][:device_id], "chained merges (A→B→C) must resolve to the final device"
  end

  test "remap_merged_devices! terminates on a breadcrumb cycle" do
    REDIS.set("#{BatchEventProcessorJob::MERGED_DEVICE_PREFIX}:#{@project.id}:#{@device.id}", 777)
    REDIS.set("#{BatchEventProcessorJob::MERGED_DEVICE_PREFIX}:#{@project.id}:777", @device.id)
    parsed = [{ project_id: @project.id, device_id: @device.id, link_id: nil }]

    assert_nothing_raised { @job.send(:remap_merged_devices!, parsed) }
  end

  test "remap_merged_devices! leaves device_id unchanged when no breadcrumb exists" do
    parsed = [{ project_id: @project.id, device_id: @device.id }]
    @job.send(:remap_merged_devices!, parsed)
    assert_equal @device.id, parsed[0][:device_id]
  end

  test "remap_merged_devices! survives a Redis failure without raising or remapping" do
    REDIS.stub(:mget, ->(*) { raise Redis::BaseError, "down" }) do
      parsed = [{ project_id: @project.id, device_id: @device.id }]
      assert_nothing_raised { @job.send(:remap_merged_devices!, parsed) }
      assert_equal @device.id, parsed[0][:device_id]
    end
  end

  # --- bulk_upsert_visitor_last_visits recency (batch path) ---

  test "bulk_upsert_visitor_last_visits refreshes updated_at on a repeat batch (merge recency)" do
    VisitorLastVisit.where(project_id: @project.id, visitor_id: @visitor.id).delete_all
    l2 = links(:second_link)
    vidx = { [@project.id, @device.id] => @visitor }

    @job.send(:bulk_upsert_visitor_last_visits,
              [{ project_id: @project.id, device_id: @device.id, link_id: @link.id }], vidx)
    r1 = VisitorLastVisit.find_by(project_id: @project.id, visitor_id: @visitor.id)
    ts1 = r1.updated_at
    sleep 1.1
    @job.send(:bulk_upsert_visitor_last_visits,
              [{ project_id: @project.id, device_id: @device.id, link_id: l2.id }], vidx)
    r2 = VisitorLastVisit.find_by(project_id: @project.id, visitor_id: @visitor.id)

    assert_equal l2.id, r2.link_id
    assert r2.updated_at > ts1, "batch path must refresh updated_at on conflict"
  end

  # --- integration: merge breadcrumb remaps a queued event through process_batch ---

  test "a queued event for a merged-away device is remapped to the target via process_batch" do
    source = Device.create!(vendor: "src-#{SecureRandom.hex(4)}", ip: "1.1.1.1",
                            remote_ip: "1.1.1.1", platform: "ios", user_agent: "Test/1.0")
    REDIS.set("#{BatchEventProcessorJob::MERGED_DEVICE_PREFIX}:#{@project.id}:#{source.id}", @device.id)
    payload = { type: Grovs::Events::APP_OPEN, project_id: @project.id,
                device_id: source.id, created_at: Time.current.iso8601(3) }

    Clickhouse.stub(:enabled?, false) do
      assert_difference -> { Event.where(device_id: @device.id, event: Grovs::Events::APP_OPEN).count }, 1 do
        @job.send(:process_batch, [payload.to_json])
      end
    end

    assert_not Event.exists?(device_id: source.id),
      "event must land on the target device, not the merged-away source"
  end

  test "upsert_user_profiles caps visitor sdk_attributes to MAX_PROPERTY_KEYS_PER_EVENT" do
    max = Analytics::Config::MAX_PROPERTY_KEYS_PER_EVENT
    attrs = (1..200).index_by { |i| "k#{i.to_s.rjust(3, '0')}" }
    @visitor.update_column(:sdk_attributes, attrs)

    visitors_index = { [@project.id, @device.id] => @visitor }
    devices = { @device.id => @device }

    captured = nil
    GeoipService.stub(:lookup, { country: "", city: "" }) do
      ClickhouseWriteService.stub(:upsert_user_profiles, ->(rows) { captured = rows }) do
        @job.send(:upsert_user_profiles, visitors_index, devices)
      end
    end

    assert_equal 1, captured.size
    row = captured.first
    assert_equal max, row[:properties].size
    assert_equal attrs.keys.sort.first(max), row[:properties].keys.sort
  end

  # A live row with no uuid outranks the backfill on last_seen and would erase it on merge.
  test "upsert_user_profiles writes the visitor uuid so live writes cannot erase a backfilled one" do
    visitors_index = { [@project.id, @device.id] => @visitor }
    devices = { @device.id => @device }

    captured = nil
    GeoipService.stub(:lookup, { country: "", city: "" }) do
      ClickhouseWriteService.stub(:upsert_user_profiles, ->(rows) { captured = rows }) do
        @job.send(:upsert_user_profiles, visitors_index, devices)
      end
    end

    assert_equal @visitor.uuid.to_s, captured.first[:uuid]
  end

  # --- missing-visitor resolution (merge race) ---

  test "resolve_missing_visitors! resolves a merged-away device via its breadcrumb" do
    survivor_dev = devices(:android_device)
    survivor_vis = visitors(:android_visitor)
    merged_dev = create_merged_away_device
    REDIS.set(BatchEventProcessorJob.merged_device_key(@project.id, merged_dev.id), survivor_dev.id)

    payload = { type: Grovs::Events::VIEW, project_id: @project.id, device_id: merged_dev.id,
                occurred_at: Time.current }
    parsed = [payload]
    projects = { @project.id => @project }
    devices_idx = { merged_dev.id => merged_dev }
    visitors_index = {} # visitor already deleted by the merge when the batch loaded visitors

    result = @job.send(:resolve_missing_visitors!, parsed, projects, devices_idx, visitors_index)

    assert_equal :resolved, result
    assert_equal survivor_dev.id, payload[:device_id]
    assert devices_idx.key?(survivor_dev.id), "survivor device must be loaded into the index"
    assert_equal survivor_vis.id, visitors_index[[@project.id, survivor_dev.id]]&.id
  end

  test "resolve_missing_visitors! re-runs the remap when a breadcrumb appears mid-pass" do
    survivor_dev = devices(:android_device)
    merged_dev = create_merged_away_device
    payload = { type: Grovs::Events::VIEW, project_id: @project.id, device_id: merged_dev.id,
                occurred_at: Time.current }
    projects = { @project.id => @project }
    devices_idx = { merged_dev.id => merged_dev }
    visitors_index = {}

    orig_remap = @job.method(:remap_merged_devices!)
    calls = 0
    result = @job.stub(:remap_merged_devices!, lambda { |payloads|
      calls += 1
      if calls == 1
        # merge commits after this pass's remap already ran
        REDIS.set(BatchEventProcessorJob.merged_device_key(@project.id, merged_dev.id), survivor_dev.id)
        nil
      else
        orig_remap.call(payloads)
      end
    }) do
      @job.send(:resolve_missing_visitors!, [payload], projects, devices_idx, visitors_index)
    end

    assert_equal :resolved, result
    assert_equal survivor_dev.id, payload[:device_id]
    assert_operator calls, :>=, 2, "a second remap pass must run after the breadcrumb appears"
  end

  test "process_batch defers the batch when a missing visitor's device is merge-locked" do
    merged_dev = create_merged_away_device
    lock_key = "#{MergeVisitorEventsJob::LOCK_PREFIX}:#{merged_dev.id}:#{@project.id}"
    REDIS.set(lock_key, "tok", ex: 60)

    event_json = {
      type: Grovs::Events::VIEW, project_id: @project.id, device_id: merged_dev.id,
      link_id: @link.id, data: nil, engagement_time: nil, created_at: "2026-06-25T12:00:00Z"
    }.to_json
    REDIS.with { |conn| conn.lpush("events:processing:#{@job.jid}", event_json) }

    result = nil
    assert_no_difference "Event.count" do
      result = @job.send(:process_batch, [event_json])
    end

    assert_equal :merge_deferred, result
    assert_equal 1, REDIS.with { |conn| conn.llen(BatchEventProcessorJob::REDIS_KEY) },
      "tray must be repushed to pending for retry"
  ensure
    REDIS.del(lock_key) if lock_key
  end

  test "process_batch parks visitorless payloads with no merge trace and processes the rest" do
    orphan_dev = create_merged_away_device
    orphan_json = {
      type: Grovs::Events::VIEW, project_id: @project.id, device_id: orphan_dev.id,
      link_id: @link.id, data: nil, engagement_time: nil, created_at: "2026-06-26T12:00:00Z"
    }.to_json
    healthy_json = {
      type: Grovs::Events::OPEN, project_id: @project.id, device_id: @device.id,
      link_id: nil, data: nil, engagement_time: nil, created_at: "2026-06-26T12:00:00Z"
    }.to_json

    result = nil
    assert_difference "Event.count", 1 do
      result = @job.send(:process_batch, [orphan_json, healthy_json])
    end

    assert_equal :success, result
    assert_equal Grovs::Events::OPEN, Event.order(:id).last.event, "only the healthy payload may insert"
    assert_equal 1, REDIS.with { |conn| conn.llen(BatchEventProcessorJob::INTEGRITY_DLQ_KEY) }
    parked = JSON.parse(REDIS.with { |conn| conn.lindex(BatchEventProcessorJob::INTEGRITY_DLQ_KEY, 0) },
      symbolize_names: true)
    assert_equal orphan_dev.id, parked[:device_id]
  end

  test "process_batch defers instead of corrupting when Redis fails during visitor resolution" do
    orphan_dev = create_merged_away_device
    event_json = {
      type: Grovs::Events::VIEW, project_id: @project.id, device_id: orphan_dev.id,
      link_id: @link.id, data: nil, engagement_time: nil, created_at: "2026-06-28T12:00:00Z"
    }.to_json
    REDIS.with { |conn| conn.lpush("events:processing:#{@job.jid}", event_json) }

    result = nil
    @job.stub(:missing_merge_state, ->(*) { raise Redis::BaseError, "mget boom" }) do
      assert_no_difference "Event.count" do
        result = @job.send(:process_batch, [event_json])
      end
    end

    assert_equal :merge_deferred, result
    assert_equal 1, REDIS.with { |conn| conn.llen(BatchEventProcessorJob::REDIS_KEY) },
      "tray must be repushed for retry, not processed with a missing visitor"
  end

  test "park_integrity_payloads! evicts oldest entries beyond the DLQ cap" do
    key = BatchEventProcessorJob::INTEGRITY_DLQ_KEY
    max = BatchEventProcessorJob::INTEGRITY_DLQ_MAX
    REDIS.with do |conn|
      conn.del(key)
      conn.pipelined { |p| max.times { p.lpush(key, "seed") } }
    end

    payload = { type: Grovs::Events::VIEW, project_id: @project.id,
                device_id: @device.id, occurred_at: Time.current }
    evictions = []
    Grovs::Metrics.stub(:increment, lambda { |name, **kw|
      evictions << kw if name == "events.integrity_dlq.evicted"
    }) do
      @job.send(:park_integrity_payloads!, [payload], [payload])
    end

    assert_equal max, REDIS.with { |conn| conn.llen(key) }, "DLQ must stay capped"
    assert_equal 1, evictions.size, "eviction must be surfaced, not silent"
    assert_equal 1, evictions.first[:by]
  end

  test "parking the same payload twice keeps a single DLQ entry" do
    payload = { type: Grovs::Events::VIEW, project_id: @project.id,
                device_id: @device.id, occurred_at: Time.current }

    @job.send(:park_integrity_payloads!, [payload], [payload])
    @job.send(:park_integrity_payloads!, [payload], [payload])

    assert_equal 1, REDIS.with { |conn| conn.llen(BatchEventProcessorJob::INTEGRITY_DLQ_KEY) },
      "tray-repush retries must not duplicate parked payloads"
  end

  test "drain_integrity_dlq! moves parked payloads back to pending" do
    2.times do |i|
      payload = { type: Grovs::Events::VIEW, project_id: @project.id,
                  device_id: @device.id + i, occurred_at: Time.current }
      @job.send(:park_integrity_payloads!, [payload], [payload])
    end

    moved = BatchEventProcessorJob.drain_integrity_dlq!

    assert_equal 2, moved
    assert_equal 0, REDIS.with { |conn| conn.llen(BatchEventProcessorJob::INTEGRITY_DLQ_KEY) }
    assert_equal 2, REDIS.with { |conn| conn.llen(BatchEventProcessorJob::REDIS_KEY) }
  end

  test "process_batch returns :success on the happy path" do
    event_json = {
      type: Grovs::Events::OPEN, project_id: @project.id, device_id: @device.id,
      link_id: nil, data: nil, engagement_time: nil, created_at: Time.current.iso8601(3)
    }.to_json

    assert_equal :success, @job.send(:process_batch, [event_json])
  end

  # Characterization: no FK on visitor_daily_statistics — adding one must be a conscious change.
  test "stat upsert for a deleted visitor id commits silently (no FK backstop)" do
    ghost_id = Visitor.maximum(:id).to_i + 100_000
    update = {
      visitor_updates: {
        stats: {
          project_id: @project.id, visitor_id: ghost_id, invited_by_id: nil,
          platform: "ios", event_date: Date.new(2026, 6, 27), metrics: { views: 1 }
        }
      },
      link_updates: nil
    }

    assert_nothing_raised { EventStatDispatchService.bulk_process_updates([update]) }
    assert VisitorDailyStatistic.exists?(visitor_id: ghost_id, project_id: @project.id),
      "orphan stat row committed — documents the residual race consequence"
  end

  # A device whose Visitor was deleted by a merge — the race under test.
  def create_merged_away_device
    Device.create!(
      user_agent: "RaceWeb/#{SecureRandom.hex(4)}",
      ip: "10.9.#{rand(256)}.#{rand(256)}", remote_ip: "10.9.#{rand(256)}.#{rand(256)}",
      platform: "web"
    )
  end
end
# rubocop:enable Metrics/ClassLength
