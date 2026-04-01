require "test_helper"

# rubocop:disable Metrics/ClassLength
class BatchEventProcessorJobTest < ActiveSupport::TestCase
  fixtures :instances, :projects, :devices, :visitors, :links, :domains, :redirect_configs, :events,
          :visitor_daily_statistics, :link_daily_statistics

  setup do
    @job = BatchEventProcessorJob.new
    @job.jid = "test-jid-#{SecureRandom.hex(4)}"
    @project = projects(:one)
    @device = devices(:ios_device)
    @visitor = visitors(:ios_visitor)
    @link = links(:basic_link)
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
    second_link = links(:second_link)
    parsed = [
      { type: Grovs::Events::VIEW, project_id: @project.id, device_id: @device.id,
        link_id: @link.id, occurred_at: Time.current },
      { type: Grovs::Events::VIEW, project_id: @project.id, device_id: @device.id,
        link_id: second_link.id, occurred_at: Time.current }
    ]
    visitors_index = { [@project.id, @device.id] => @visitor }

    @job.send(:bulk_upsert_visitor_last_visits, parsed, visitors_index)

    vlv = VisitorLastVisit.find_by(project_id: @project.id, visitor_id: @visitor.id)
    assert_equal second_link.id, vlv.link_id, "Last event's link should win"
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
      conn.del("events:dedup:#{@device.id}:view") if @device
      conn.del("events:dedup:#{devices(:android_device).id}:view")
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
    REDIS.del("events:dedup:#{@device.id}:view")

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
      conn.set("events:dedup:#{@device.id}:view", "1", ex: 60)
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

  # --- enqueue_if_backlog ---

  test "enqueue_if_backlog enqueues when pending events exist" do
    enqueued = false
    # Mock llen to return positive count (avoids shared Redis queue contention)
    REDIS.stub(:llen, 5) do
      BatchEventProcessorJob.stub(:perform_async, -> { enqueued = true }) do
        @job.send(:enqueue_if_backlog)
      end
    end

    assert enqueued, "Should enqueue follow-up job when events are pending"
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
      assert_equal false, result, "process_batch should return false on DB error"
    end

    # Events should be back in the pending queue
    REDIS.with do |conn|
      pending = conn.lrange(BatchEventProcessorJob::REDIS_KEY, 0, -1)
      assert_includes pending, event_json, "Events should be repushed to pending"
    end
  end

  test "process_batch cleans up dedup keys on failure" do
    # Clear any existing dedup key
    REDIS.with { |conn| conn.del("events:dedup:#{@device.id}:view") }

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
    assert_equal false, REDIS.with { |conn| conn.exists?("events:dedup:#{@device.id}:view") },
      "Dedup key should be cleaned up on batch failure"
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

    # The skipped VIEW's device should be in dedup_device_ids
    assert_includes dedup_device_ids, @device.id
  end

  test "touch_deduped_views updates created_at on recent VIEWs" do
    # Create a VIEW event within the 10-second window
    recent_view = Event.create!(
      project_id: @project.id, device_id: @device.id,
      event: Grovs::Events::VIEW, platform: @device.platform,
      created_at: 3.seconds.ago, processed: true
    )
    original_time = recent_view.created_at

    @job.send(:touch_deduped_views, Set.new([@device.id]))

    recent_view.reload
    assert_operator recent_view.created_at, :>, original_time,
      "created_at should be updated to a more recent time"
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
      assert_equal true, result, "Should return true for empty parsed batch"
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
      assert_equal true, result, "process_batch should succeed"
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
end
# rubocop:enable Metrics/ClassLength
