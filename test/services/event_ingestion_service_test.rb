require "test_helper"

class EventIngestionServiceTest < ActiveSupport::TestCase # rubocop:disable Metrics/ClassLength
  fixtures :instances, :projects, :devices, :visitors, :domains, :links,
           :redirect_configs, :events, :visitor_last_visits, :campaigns

  setup do
    @project = projects(:one)
    @device = devices(:ios_device)
    @device.update_columns(vendor: "test-vendor-abc", app_version: "2.1.0", build: "4455")
    @visitor = visitors(:ios_visitor)
    @link = links(:basic_link)
    @data = { "source" => "test", "campaign" => "spring" }
    # Parallel tests share Redis — flush the visitor cache so
    # visitor_for_project_id always hits the DB (transaction-isolated).
    @visitor.send(:clear_cache)
  end

  # ---------------------------------------------------------------------------
  # enqueue_events — batch LPUSH with Sidekiq fallback
  # ---------------------------------------------------------------------------

  test "enqueue_events with empty payloads is a no-op" do
    assert_nil EventIngestionService.send(:enqueue_events, [])
  end

  test "enqueue_events LPUSHes json payloads onto the batch queue" do
    REDIS.del(BatchEventProcessorJob::REDIS_KEY)
    EventIngestionService.send(:enqueue_events,
                               [{ type: "view", project_id: 1, event_id: "eid-1" },
                                { type: "open", project_id: 2, event_id: "eid-2" }])

    queued = REDIS.lrange(BatchEventProcessorJob::REDIS_KEY, 0, -1).map { |j| JSON.parse(j) }
    assert_equal 2, queued.size
    assert_includes queued, { "type" => "view", "project_id" => 1, "event_id" => "eid-1" }
    assert_includes queued, { "type" => "open", "project_id" => 2, "event_id" => "eid-2" }
  ensure
    REDIS.del(BatchEventProcessorJob::REDIS_KEY)
  end

  test "enqueue_events falls back to Sidekiq when Redis LPUSH fails" do
    enqueued = []
    REDIS.stub(:lpush, ->(*) { raise Redis::BaseError, "down" }) do
      LogEventJob.stub(:perform_async, ->(*args) { enqueued << args }) do
        EventIngestionService.send(:enqueue_events, [{ type: "view", project_id: 1, device_id: 5, event_id: "eid-1" }])
      end
    end
    assert_equal 1, enqueued.size
    assert_equal "view", enqueued.first[0]
  end

  test "enqueue_events raises in dev/test when a payload is missing event_id" do
    assert_raises(ArgumentError) do
      EventIngestionService.send(:enqueue_events, [{ type: "view", project_id: 1 }])
    end
  end

  test "enqueue_events backstop-recomputes a deterministic id for a missing event_id outside dev/test (no drop, no collapse)" do
    REDIS.del(BatchEventProcessorJob::REDIS_KEY)
    payload = { type: "view", project_id: 1 }
    Rails.env.stub(:local?, false) do
      EventIngestionService.send(:enqueue_events, [payload])
    end
    queued = REDIS.lrange(BatchEventProcessorJob::REDIS_KEY, 0, -1).map { |j| JSON.parse(j, symbolize_names: true) }
    assert_equal 1, queued.size
    assert_match(/\A[a-f0-9]{32}\z/, queued.first[:event_id], "missing id should be backstop-recomputed as a deterministic md5, not a UUID")
    # Deterministic: the SAME missing-id payload recomputes to the SAME id (so a retry collapses).
    assert_equal EventIngestionService.send(:backstop_event_id, payload), queued.first[:event_id]
  ensure
    REDIS.del(BatchEventProcessorJob::REDIS_KEY)
  end

  # ---------------------------------------------------------------------------
  # Phase 1: frozen event-time source capture
  # ---------------------------------------------------------------------------

  test "enqueue_event freezes link source and event_id into the payload" do
    @link.update_columns(campaign_id: campaigns(:one).id, visitor_id: @visitor.id, sdk_generated: true)
    REDIS.del(BatchEventProcessorJob::REDIS_KEY)
    EventIngestionService.send(:enqueue_event, Grovs::Events::OPEN, @project, @device, nil, @link, nil,
                               event_name: "", session_id: "sess-1")

    payload = JSON.parse(REDIS.lrange(BatchEventProcessorJob::REDIS_KEY, 0, -1).first, symbolize_names: true)
    assert_equal campaigns(:one).id, payload[:campaign_id]
    assert_equal true, payload[:sdk_generated]
    assert_equal @visitor.id, payload[:link_visitor_id]
    assert_match(/\A[a-f0-9]{32}\z/, payload[:event_id], "event_id should be a deterministic md5 content hash")
  ensure
    REDIS.del(BatchEventProcessorJob::REDIS_KEY)
  end

  test "log_async freezes link source into the payload (public entry point)" do
    @link.update_columns(campaign_id: campaigns(:one).id, visitor_id: @visitor.id, sdk_generated: true)
    REDIS.del(BatchEventProcessorJob::REDIS_KEY)
    EventIngestionService.log_async(Grovs::Events::OPEN, @project, @device, nil, @link)

    payload = JSON.parse(REDIS.lrange(BatchEventProcessorJob::REDIS_KEY, 0, -1).first, symbolize_names: true)
    assert_equal campaigns(:one).id, payload[:campaign_id]
    assert_equal true, payload[:sdk_generated]
    assert_equal @visitor.id, payload[:link_visitor_id]
    assert_match(/\A[a-f0-9]{32}\z/, payload[:event_id], "event_id should be a deterministic md5 content hash")
  ensure
    REDIS.del(BatchEventProcessorJob::REDIS_KEY)
  end

  test "enqueue_event freezes organic defaults when there is no link" do
    REDIS.del(BatchEventProcessorJob::REDIS_KEY)
    EventIngestionService.send(:enqueue_event, Grovs::Events::APP_OPEN, @project, @device, nil, nil, nil)

    payload = JSON.parse(REDIS.lrange(BatchEventProcessorJob::REDIS_KEY, 0, -1).first, symbolize_names: true)
    assert_nil payload[:campaign_id]
    assert_equal false, payload[:sdk_generated]
    assert_nil payload[:link_visitor_id]
    assert_match(/\A[a-f0-9]{32}\z/, payload[:event_id], "event_id should be a deterministic md5 content hash")
  ensure
    REDIS.del(BatchEventProcessorJob::REDIS_KEY)
  end

  test "frozen_ch_fields collapses a byte-identical retry to one event_id (truth-first dedup)" do
    t = Time.utc(2026, 6, 30, 12, 0, 0)
    a = EventIngestionService.frozen_ch_fields(Grovs::Events::APP_OPEN, @project.id, @device.id, nil, t, "", "", nil, nil)
    b = EventIngestionService.frozen_ch_fields(Grovs::Events::APP_OPEN, @project.id, @device.id, nil, t, "", "", nil, nil)
    assert_equal a[:event_id], b[:event_id],
                 "an identical retry MUST share an event_id so ReplacingMergeTree collapses it"
    assert_match(/\A[a-f0-9]{32}\z/, a[:event_id])
  end

  test "frozen_ch_fields keeps same-ms TIME_SPENT distinct when engagement_time differs" do
    t = Time.utc(2026, 6, 30, 12, 0, 0)
    a = EventIngestionService.frozen_ch_fields(Grovs::Events::TIME_SPENT, @project.id, @device.id, nil, t, "s", "x", 10, nil)
    b = EventIngestionService.frozen_ch_fields(Grovs::Events::TIME_SPENT, @project.id, @device.id, nil, t, "s", "x", 25, nil)
    assert_not_equal a[:event_id], b[:event_id],
                     "two same-ms time_spent with different durations must not collapse"
  end

  test "frozen event_id equals the backstop recompute from the serialized payload (cross-path guard)" do
    REDIS.del(BatchEventProcessorJob::REDIS_KEY)
    EventIngestionService.send(:enqueue_event, Grovs::Events::TIME_SPENT, @project, @device, nil, @link, 42,
                               event_name: "screen", session_id: "sess-9")
    payload = JSON.parse(REDIS.lrange(BatchEventProcessorJob::REDIS_KEY, 0, -1).first, symbolize_names: true)
    # The frozen id is computed from a Time + raw engagement_time; the backstop recomputes
    # from the payload's iso8601(3) STRING + the same clamp. They MUST match or a recovered
    # payload would stop deduping against the original.
    assert_equal payload[:event_id], EventIngestionService.send(:backstop_event_id, payload)
  ensure
    REDIS.del(BatchEventProcessorJob::REDIS_KEY)
  end

  test "frozen event_id equals the backstop recompute for a property-bearing custom event" do
    REDIS.del(BatchEventProcessorJob::REDIS_KEY)
    props = { "step" => "1", "nested" => { "b" => "2", "a" => "1" } }
    EventIngestionService.send(:enqueue_event, Grovs::Events::CUSTOM, @project, @device, props, @link, nil,
                               event_name: "purchase", session_id: "sess-p")
    payload = JSON.parse(REDIS.lrange(BatchEventProcessorJob::REDIS_KEY, 0, -1).first, symbolize_names: true)

    assert_equal payload[:event_id], EventIngestionService.send(:backstop_event_id, payload)
  ensure
    REDIS.del(BatchEventProcessorJob::REDIS_KEY)
  end

  test "property-bearing event hashes identically across live, backstop, backfill, and archive input forms" do
    t = Time.utc(2026, 7, 13, 12, 0, 0)
    base = { project_id: @project.id, device_id: @device.id, event_type: Grovs::Events::CUSTOM,
             created_at: t, event_name: "purchase", session_id: "sess-x", link_id: 0 }

    live     = ClickhouseWriteService.generate_event_id(**base, properties: { "step" => "1", "nested" => { "a" => "1" } })
    backstop = ClickhouseWriteService.generate_event_id(**base, properties: { step: "1", nested: { a: "1" } })
    pg_form  = ClickhouseWriteService.generate_event_id(**base, properties: '{"nested":{"a":"1"},"step":"1"}')
    archive  = ClickhouseWriteService.generate_event_id(**base.merge(created_at: t.iso8601(3)),
                                                        properties: '{"step":"1","nested":{"a":"1"}}')

    assert_equal live, backstop, "symbolized payload round-trip must not rekey"
    assert_equal live, pg_form, "PG JSON-string form must not rekey"
    assert_equal live, archive, "archive string created_at + JSON data must not rekey"
  end

  # ---------------------------------------------------------------------------
  # log — synchronous event creation
  # ---------------------------------------------------------------------------

  test "log creates event with all attributes correctly populated" do
    assert_difference "Event.count", 1 do
      event = EventIngestionService.log(
        Grovs::Events::VIEW, @project, @device, @data, @link, 5000
      )

      assert event.persisted?
      assert_equal Grovs::Events::VIEW, event.event
      assert_equal @project.id, event.project_id
      assert_equal @device.id, event.device_id
      assert_equal @link.id, event.link_id
      assert_equal @data, event.data
    end
  end

  test "log denormalizes all device fields onto event" do
    event = EventIngestionService.log(
      Grovs::Events::OPEN, @project, @device, @data, @link
    )

    assert_equal "192.168.1.1", event.ip
    assert_equal "10.0.0.1", event.remote_ip
    assert_equal "test-vendor-abc", event.vendor_id
    assert_equal "ios", event.platform
    assert_equal "2.1.0", event.app_version
    assert_equal "4455", event.build
  end

  test "log denormalizes link path onto event" do
    event = EventIngestionService.log(
      Grovs::Events::VIEW, @project, @device, @data, @link
    )

    assert_equal "test-path", event.path
  end

  test "log works without a link" do
    event = EventIngestionService.log(
      Grovs::Events::APP_OPEN, @project, @device, @data, nil
    )

    assert event.persisted?
    assert_nil event.link_id
    assert_nil event.path
  end


  test "log respects custom created_at" do
    custom_time = Time.new(2026, 1, 15, 12, 0, 0, "+00:00")

    event = EventIngestionService.log(
      Grovs::Events::VIEW, @project, @device, @data, @link,
      nil, created_at: custom_time
    )

    assert_equal custom_time.to_i, event.created_at.to_i
  end

  test "log touches the visitor updated_at" do
    original_updated = @visitor.updated_at

    travel_to 1.minute.from_now do
      EventIngestionService.log(
        Grovs::Events::VIEW, @project, @device, @data, @link
      )
    end

    assert @visitor.reload.updated_at > original_updated
  end

  test "log does not crash when device has no visitor for this project" do
    orphan_device = Device.create!(
      user_agent: "Orphan/1.0", ip: "4.4.4.4", remote_ip: "4.4.4.4", platform: "ios"
    )

    event = EventIngestionService.log(
      Grovs::Events::VIEW, @project, orphan_device, @data, @link
    )

    assert event.persisted?
  end

  test "log calls EventStatDispatchService to process the event" do
    dispatch_called_with = nil
    EventStatDispatchService.stub(:call_normal_event, ->(event) { dispatch_called_with = event }) do
      event = EventIngestionService.log(
        Grovs::Events::VIEW, @project, @device, @data, @link
      )
      assert_equal event.id, dispatch_called_with.id
    end
  end

  test "log queues ProcessNormalEventJob when stat dispatch fails" do
    queued_id = nil
    EventStatDispatchService.stub(:call_normal_event, ->(_) { raise "boom" }) do
      ProcessNormalEventJob.stub(:perform_async, ->(id) { queued_id = id }) do
        event = EventIngestionService.log(
          Grovs::Events::VIEW, @project, @device, @data, @link
        )
        assert_equal event.id, queued_id
      end
    end
  end

  # ---------------------------------------------------------------------------
  # log_event_without_view_duplicates — VIEW dedup (5s window)
  # ---------------------------------------------------------------------------

  test "dedup returns existing VIEW event and skips reprocessing" do
    first = EventIngestionService.log(
      Grovs::Events::VIEW, @project, @device, @data, @link
    )

    dispatch_called = false
    EventStatDispatchService.stub(:call_normal_event, ->(_) { dispatch_called = true }) do
      result = EventIngestionService.log_event_without_view_duplicates(
        Grovs::Events::VIEW, @project, @device, @data, @link
      )

      assert_equal first.id, result.id, "Should return the same event, not create a new one"
    end

    assert_not dispatch_called,
               "Deduped VIEW should NOT be reprocessed through EventStatDispatchService"
  end

  test "dedup rolls forward created_at on duplicate VIEW" do
    first = EventIngestionService.log(
      Grovs::Events::VIEW, @project, @device, @data, @link
    )
    original_created = first.created_at

    travel_to 2.seconds.from_now do
      EventStatDispatchService.stub(:call_normal_event, ->(_) {}) do
        EventIngestionService.log_event_without_view_duplicates(
          Grovs::Events::VIEW, @project, @device, @data, @link
        )
      end

      assert first.reload.created_at > original_created,
             "created_at should roll forward to keep dedup window active"
    end
  end

  test "dedup creates new VIEW event when older than 5 seconds" do
    first = EventIngestionService.log(
      Grovs::Events::VIEW, @project, @device, @data, @link
    )

    travel_to 6.seconds.from_now do
      assert_difference "Event.count", 1 do
        result = EventIngestionService.log_event_without_view_duplicates(
          Grovs::Events::VIEW, @project, @device, @data, @link
        )
        assert_not_equal first.id, result.id
      end
    end
  end

  test "dedup does not apply to non-VIEW events" do
    EventIngestionService.log(
      Grovs::Events::OPEN, @project, @device, @data, @link
    )

    assert_difference "Event.count", 1 do
      EventIngestionService.log_event_without_view_duplicates(
        Grovs::Events::OPEN, @project, @device, @data, @link
      )
    end
  end

  test "VIEW dedup is project-scoped: same device on a different project is NOT deduped" do
    project_two = projects(:two)
    Visitor.create!(project: project_two, device: @device, web_visitor: false)

    first = EventIngestionService.log(Grovs::Events::VIEW, @project, @device, @data, @link)

    EventStatDispatchService.stub(:call_normal_event, ->(_) {}) do
      result = EventIngestionService.log_event_without_view_duplicates(
        Grovs::Events::VIEW, project_two, @device, @data, links(:second_link)
      )

      assert_not_equal first.id, result.id,
        "a VIEW on a different project must not be deduped against another project's VIEW"
      assert_equal project_two.id, result.project_id
    end
  end

  # ---------------------------------------------------------------------------
  # log_async — 3-tier fallback chain
  # ---------------------------------------------------------------------------

  test "log_async pushes correct JSON payload to Redis events queue" do
    pushed_key = nil
    pushed_payload = nil

    REDIS.stub(:lpush, lambda { |key, payload| 
      pushed_key = key
      pushed_payload = payload
    }) do
      EventIngestionService.log_async(
        Grovs::Events::VIEW, @project, @device, @data, @link, 3000
      )
    end

    assert_equal BatchEventProcessorJob::REDIS_KEY, pushed_key

    parsed = JSON.parse(pushed_payload)
    assert_equal Grovs::Events::VIEW, parsed["type"]
    assert_equal @project.id, parsed["project_id"]
    assert_equal @device.id, parsed["device_id"]
    assert_equal @link.id, parsed["link_id"]
    assert_equal 3000, parsed["engagement_time"]
    assert_equal @data, parsed["data"]
    assert parsed["created_at"].present?, "Should include a timestamp"
  end

  test "log_async payload has null link_id when no link provided" do
    pushed_payload = nil

    REDIS.stub(:lpush, ->(_, payload) { pushed_payload = payload }) do
      EventIngestionService.log_async(
        Grovs::Events::APP_OPEN, @project, @device, @data, nil
      )
    end

    parsed = JSON.parse(pushed_payload)
    assert_nil parsed["link_id"]
  end

  test "log_async payload includes custom created_at when provided" do
    pushed_payload = nil
    custom_time = Time.new(2026, 2, 20, 8, 0, 0, "+00:00")

    REDIS.stub(:lpush, ->(_, payload) { pushed_payload = payload }) do
      EventIngestionService.log_async(
        Grovs::Events::VIEW, @project, @device, @data, @link, nil,
        created_at: custom_time
      )
    end

    parsed = JSON.parse(pushed_payload)
    parsed_time = Time.parse(parsed["created_at"])
    assert_equal custom_time.to_i, parsed_time.to_i,
                 "Custom created_at should appear in the Redis payload"
  end

  test "log_async falls back to LogEventJob when Redis LPUSH fails" do
    sidekiq_args = nil

    REDIS.stub(:lpush, ->(*_) { raise Redis::BaseError, "connection refused" }) do
      LogEventJob.stub(:perform_async, ->(*args) { sidekiq_args = args }) do
        EventIngestionService.log_async(
          Grovs::Events::OPEN, @project, @device, @data, @link
        )
      end
    end

    assert_not_nil sidekiq_args, "Should have enqueued LogEventJob"
    assert_equal Grovs::Events::OPEN, sidekiq_args[0]
    assert_equal @project.id, sidekiq_args[1]
    assert_equal @device.id, sidekiq_args[2]
  end

  test "log_async falls back to sync DB write when both Redis and Sidekiq fail" do
    REDIS.stub(:lpush, ->(*_) { raise Redis::BaseError, "connection refused" }) do
      LogEventJob.stub(:perform_async, ->(*_) { raise Redis::BaseError, "still down" }) do
        assert_difference "Event.count", 1 do
          EventIngestionService.log_async(
            Grovs::Events::APP_OPEN, @project, @device, @data, nil
          )
        end
      end
    end

    last_event = Event.order(id: :desc).first
    assert_equal Grovs::Events::APP_OPEN, last_event.event
    assert_equal @project.id, last_event.project_id
  end

  test "log_async swallows error when all three tiers fail" do
    REDIS.stub(:lpush, ->(*_) { raise Redis::BaseError, "down" }) do
      LogEventJob.stub(:perform_async, ->(*_) { raise Redis::BaseError, "down" }) do
        Event.stub(:new, -> { raise ActiveRecord::ConnectionNotEstablished, "db down" }) do
          assert_no_difference "Event.count" do
            EventIngestionService.log_async(
              Grovs::Events::VIEW, @project, @device, @data, @link
            )
          end
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # log_async — VisitorLastVisit upsert
  # ---------------------------------------------------------------------------

  test "log_async upserts visitor_last_visit with current link" do
    project_two = projects(:two)
    android_device = devices(:android_device)
    visitor_two = Visitor.create!(project: project_two, device: android_device, web_visitor: false)

    REDIS.stub(:lpush, ->(*_) {}) do
      EventIngestionService.log_async(
        Grovs::Events::VIEW, project_two, android_device, @data, links(:second_link)
      )
    end

    vlv = VisitorLastVisit.find_by(project_id: project_two.id, visitor_id: visitor_two.id)
    assert_not_nil vlv
    assert_equal links(:second_link).id, vlv.link_id
  end

  test "log_async skips visitor_last_visit when no link" do
    assert_no_difference "VisitorLastVisit.count" do
      REDIS.stub(:lpush, ->(*_) {}) do
        EventIngestionService.log_async(
          Grovs::Events::APP_OPEN, @project, @device, @data, nil
        )
      end
    end
  end

  test "log_async updates visitor_last_visit link on repeat visit" do
    # Create the initial visit record inline (fixture is intentionally empty)
    vlv = VisitorLastVisit.create!(project: @project, visitor: @visitor, link: @link)

    new_link = Link.create!(
      domain: domains(:one), path: "repeat-visit-#{SecureRandom.hex(4)}",
      title: "New", active: true, redirect_config: @link.redirect_config,
      generated_from_platform: "ios"
    )

    REDIS.stub(:lpush, ->(*_) {}) do
      EventIngestionService.log_async(
        Grovs::Events::VIEW, @project, @device, @data, new_link
      )
    end

    assert_equal new_link.id, vlv.reload.link_id,
                 "visitor_last_visit should update to the newest link"
  end

  test "log_async preserves created_at on visitor_last_visit update" do
    original_time = 3.days.ago.change(usec: 0)
    vlv = VisitorLastVisit.create!(project: @project, visitor: @visitor, link: @link)
    vlv.update_columns(created_at: original_time)

    new_link = Link.create!(
      domain: domains(:one), path: "ts-test-#{SecureRandom.hex(4)}",
      title: "TS", active: true, redirect_config: @link.redirect_config,
      generated_from_platform: "ios"
    )

    REDIS.stub(:lpush, ->(*_) {}) do
      EventIngestionService.log_async(
        Grovs::Events::VIEW, @project, @device, @data, new_link
      )
    end

    vlv.reload
    assert_equal original_time, vlv.created_at,
                 "upsert should not overwrite created_at on existing records"
    assert_equal new_link.id, vlv.link_id
  end

  test "log_async gracefully handles FK violation from deleted visitor" do
    # Simulate a stale cached visitor: lookup returns a visitor object
    # whose row has been deleted from the DB (e.g. by a concurrent merge job).
    ghost_visitor = Visitor.create!(project: @project, device: @device, web_visitor: false)
    ghost_id = ghost_visitor.id
    # Clear dependent notification_messages before the raw .delete: they are
    # auto-created by Visitor's after_create_commit when an active notification
    # exists (only in the full suite), and .delete skips dependent: :destroy.
    ghost_visitor.notification_messages.delete_all
    ghost_visitor.delete

    fake_visitor = Visitor.new(id: ghost_id, project: @project, device: @device)
    @device.stub(:visitor_for_project_id, ->(_) { fake_visitor }) do
      assert_nothing_raised do
        REDIS.stub(:lpush, ->(*_) {}) do
          EventIngestionService.log_async(
            Grovs::Events::VIEW, @project, @device, @data, @link
          )
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Referral tracking (INSTALL and REINSTALL)
  # ---------------------------------------------------------------------------

  test "INSTALL with referral link sets inviter and creates USER_REFERRED event" do
    installer_device, installer_visitor = create_fresh_device_and_visitor("ios")
    referrer_device, referrer_visitor = create_fresh_device_and_visitor("android")
    @link.update_column(:visitor_id, referrer_visitor.id)
    @link.reload

    user_referred_before = Event.where(event: Grovs::Events::USER_REFERRED).count

    EventIngestionService.log(
      Grovs::Events::INSTALL, @project, installer_device, @data, @link
    )

    assert_equal referrer_visitor.id, installer_visitor.reload.inviter_id,
                 "Installer's visitor should have inviter_id set to the link owner"

    assert_equal user_referred_before + 1,
                 Event.where(event: Grovs::Events::USER_REFERRED).count,
                 "Should create a USER_REFERRED event for the referrer"

    referred_event = Event.where(event: Grovs::Events::USER_REFERRED).order(id: :desc).first
    assert_equal referrer_device.id, referred_event.device_id,
                 "USER_REFERRED event should be on the referrer's device, not the installer's"
  end

  test "REINSTALL also triggers referral tracking" do
    installer_device, installer_visitor = create_fresh_device_and_visitor("ios")
    _, referrer_visitor = create_fresh_device_and_visitor("android")
    @link.update_column(:visitor_id, referrer_visitor.id)
    @link.reload

    EventIngestionService.log(
      Grovs::Events::REINSTALL, @project, installer_device, @data, @link
    )

    assert_equal referrer_visitor.id, installer_visitor.reload.inviter_id,
                 "REINSTALL should set inviter_id just like INSTALL"
    assert Event.where(event: Grovs::Events::USER_REFERRED).exists?,
           "REINSTALL should create USER_REFERRED event"
  end

  test "self-referral: install via own link sets self as inviter" do
    # The installer's visitor IS the link owner — a self-referral.
    # Current behavior: sets inviter_id to self and creates USER_REFERRED for self.
    # This documents the behavior (arguably a bug).
    device, visitor = create_fresh_device_and_visitor("ios")
    @link.update_column(:visitor_id, visitor.id)
    @link.reload

    user_referred_before = Event.where(event: Grovs::Events::USER_REFERRED).count

    EventIngestionService.log(
      Grovs::Events::INSTALL, @project, device, @data, @link
    )

    assert_equal visitor.id, visitor.reload.inviter_id,
                 "Self-referral: visitor becomes their own inviter"
    assert_equal user_referred_before + 1,
                 Event.where(event: Grovs::Events::USER_REFERRED).count,
                 "Self-referral still creates USER_REFERRED event"
  end

  test "install does not overwrite existing inviter but still creates USER_REFERRED" do
    installer_device, installer_visitor = create_fresh_device_and_visitor("ios")
    installer_visitor.update!(inviter_id: 99999)
    _, referrer_visitor = create_fresh_device_and_visitor("android")
    @link.update_column(:visitor_id, referrer_visitor.id)
    @link.reload

    user_referred_before = Event.where(event: Grovs::Events::USER_REFERRED).count

    EventIngestionService.log(
      Grovs::Events::INSTALL, @project, installer_device, @data, @link
    )

    assert_equal 99999, installer_visitor.reload.inviter_id,
                 "Should not overwrite an existing inviter_id"

    # BUG: USER_REFERRED is created unconditionally — the inviter_id guard
    # does not protect the event creation. This double-counts referrals.
    assert_equal user_referred_before + 1,
                 Event.where(event: Grovs::Events::USER_REFERRED).count,
                 "USER_REFERRED is created even when inviter already exists (double-count bug)"
  end

  test "non-install events never trigger referral logic" do
    device, visitor = create_fresh_device_and_visitor("ios")
    _, referrer_visitor = create_fresh_device_and_visitor("android")
    @link.update_column(:visitor_id, referrer_visitor.id)
    @link.reload

    [Grovs::Events::VIEW, Grovs::Events::OPEN, Grovs::Events::APP_OPEN].each do |event_type|
      EventIngestionService.log(event_type, @project, device, @data, @link)
    end

    assert_nil visitor.reload.inviter_id
    assert_not Event.where(event: Grovs::Events::USER_REFERRED, device_id: device.id).exists?
  end

  test "install without a link does not set inviter" do
    device, visitor = create_fresh_device_and_visitor("ios")

    EventIngestionService.log(
      Grovs::Events::INSTALL, @project, device, @data, nil
    )

    assert_nil visitor.reload.inviter_id
  end

  test "install with link that has no visitor does not set inviter" do
    device, visitor = create_fresh_device_and_visitor("ios")
    @link.update_column(:visitor_id, nil)
    @link.reload

    EventIngestionService.log(
      Grovs::Events::INSTALL, @project, device, @data, @link
    )

    assert_nil visitor.reload.inviter_id
  end

  # ---------------------------------------------------------------------------
  # log_async — enrichment fields (event_name, session_id, tags)
  # ---------------------------------------------------------------------------

  test "log_async includes event_name, session_id, tags in Redis payload" do
    pushed_payload = nil

    REDIS.stub(:lpush, ->(_, payload) { pushed_payload = payload }) do
      EventIngestionService.log_async(
        Grovs::Events::CUSTOM, @project, @device, @data, @link, nil,
        event_name: "add_to_cart", session_id: "sess-123", tags: ["checkout", "promo"]
      )
    end

    parsed = JSON.parse(pushed_payload)
    assert_equal "add_to_cart", parsed["event_name"]
    assert_equal "sess-123", parsed["session_id"]
    assert_equal ["checkout", "promo"], parsed["tags"]
  end

  test "log_async defaults enrichment fields to empty when omitted" do
    pushed_payload = nil

    REDIS.stub(:lpush, ->(_, payload) { pushed_payload = payload }) do
      EventIngestionService.log_async(
        Grovs::Events::VIEW, @project, @device, @data, @link
      )
    end

    parsed = JSON.parse(pushed_payload)
    assert_equal "", parsed["event_name"]
    assert_equal "", parsed["session_id"]
    assert_equal [], parsed["tags"]
  end

  test "log_async truncates oversized event_name and session_id" do
    pushed_payload = nil
    long_string = "x" * 1000

    REDIS.stub(:lpush, ->(_, payload) { pushed_payload = payload }) do
      EventIngestionService.log_async(
        Grovs::Events::CUSTOM, @project, @device, @data, @link, nil,
        event_name: long_string, session_id: long_string
      )
    end

    parsed = JSON.parse(pushed_payload)
    max = Grovs::Enrichment::MAX_STRING_LENGTH
    assert_equal max, parsed["event_name"].length
    assert_equal max, parsed["session_id"].length
  end

  test "log_async caps tags array size and truncates tag values" do
    pushed_payload = nil
    many_tags = (1..50).map { |i| "tag-#{'z' * 300}-#{i}" }

    REDIS.stub(:lpush, ->(_, payload) { pushed_payload = payload }) do
      EventIngestionService.log_async(
        Grovs::Events::CUSTOM, @project, @device, @data, @link, nil,
        tags: many_tags
      )
    end

    parsed = JSON.parse(pushed_payload)
    max_tags = Grovs::Enrichment::MAX_TAGS
    max_len = Grovs::Enrichment::MAX_STRING_LENGTH
    assert_equal max_tags, parsed["tags"].size, "Tags should be capped at #{max_tags}"
    parsed["tags"].each do |tag|
      assert tag.length <= max_len, "Each tag should be truncated to #{max_len} chars"
    end
  end

  test "log_async Sidekiq fallback also sanitizes oversized fields" do
    sidekiq_args = nil
    long_string = "x" * 1000
    many_tags = (1..50).map { |i| "tag-#{i}" }

    REDIS.stub(:lpush, ->(*_) { raise Redis::BaseError, "down" }) do
      LogEventJob.stub(:perform_async, ->(*args) { sidekiq_args = args }) do
        EventIngestionService.log_async(
          Grovs::Events::CUSTOM, @project, @device, @data, @link, nil,
          event_name: long_string, session_id: long_string, tags: many_tags
        )
      end
    end

    max = Grovs::Enrichment::MAX_STRING_LENGTH
    assert_equal max, sidekiq_args[7].length, "event_name should be truncated in Sidekiq fallback"
    assert_equal max, sidekiq_args[8].length, "session_id should be truncated in Sidekiq fallback"
    assert_equal Grovs::Enrichment::MAX_TAGS, sidekiq_args[9].size, "tags should be capped in Sidekiq fallback"
  end

  test "log_async sync fallback preserves enrichment fields when Redis and Sidekiq both fail" do
    REDIS.stub(:lpush, ->(*_) { raise Redis::BaseError, "connection refused" }) do
      LogEventJob.stub(:perform_async, ->(*_) { raise Redis::BaseError, "connection refused" }) do
        assert_difference "Event.count", 1 do
          EventIngestionService.log_async(
            Grovs::Events::CUSTOM, @project, @device, { "item" => "sku-1" }, @link, nil,
            event_name: "add_to_cart", session_id: "sess-sync-789", tags: ["checkout", "mobile"]
          )
        end
      end
    end

    event = Event.order(created_at: :desc).first
    assert_equal Grovs::Events::CUSTOM, event.event
    assert_equal "add_to_cart", event.event_name
    assert_equal "sess-sync-789", event.session_id
    assert_equal ["checkout", "mobile"], event.tags
    assert_equal({ "item" => "sku-1" }, event.data)
  end

  test "enqueue_events sync fallback preserves batch event when Redis and Sidekiq both fail" do
    payload = {
      type: Grovs::Events::CUSTOM,
      project_id: @project.id,
      device_id: @device.id,
      data: { "item" => "sku-2" },
      link_id: @link.id,
      engagement_time: nil,
      created_at: Time.current.iso8601(3),
      event_name: "batch_checkout",
      session_id: "sess-batch-sync",
      tags: ["batch", "checkout"],
      event_id: "eid-batch-sync"
    }

    REDIS.stub(:lpush, ->(*_) { raise Redis::BaseError, "connection refused" }) do
      LogEventJob.stub(:perform_async, ->(*_) { raise Redis::BaseError, "connection refused" }) do
        assert_difference "Event.count", 1 do
          EventIngestionService.enqueue_events([payload])
        end
      end
    end

    event = Event.order(created_at: :desc).first
    assert_equal Grovs::Events::CUSTOM, event.event
    assert_equal "batch_checkout", event.event_name
    assert_equal "sess-batch-sync", event.session_id
    assert_equal ["batch", "checkout"], event.tags
    assert_equal({ "item" => "sku-2" }, event.data)
    assert_equal @link.id, event.link_id
  end

  test "log (sync path) truncates oversized enrichment fields on Event record" do
    max_len = Grovs::Enrichment::MAX_STRING_LENGTH
    max_tags = Grovs::Enrichment::MAX_TAGS
    huge_name = "x" * 10_000
    huge_session = "s" * 10_000
    huge_tags = (1..100).map { "t" * 500 }

    event = EventIngestionService.log(
      Grovs::Events::CUSTOM, @project, @device, nil, @link, nil,
      event_name: huge_name, session_id: huge_session, tags: huge_tags
    )

    assert event.persisted?
    assert_equal max_len, event.event_name.length, "event_name must be truncated in sync path"
    assert_equal max_len, event.session_id.length, "session_id must be truncated in sync path"
    assert_equal max_tags, event.tags.size, "tags must be capped in sync path"
    event.tags.each do |tag|
      assert tag.length <= max_len, "each tag must be truncated in sync path"
    end
  end

  test "log_async fallback to Sidekiq passes enrichment fields" do
    sidekiq_args = nil

    REDIS.stub(:lpush, ->(*_) { raise Redis::BaseError, "connection refused" }) do
      LogEventJob.stub(:perform_async, ->(*args) { sidekiq_args = args }) do
        EventIngestionService.log_async(
          Grovs::Events::CUSTOM, @project, @device, @data, @link, nil,
          event_name: "checkout", session_id: "sess-456", tags: ["purchase"]
        )
      end
    end

    assert_not_nil sidekiq_args
    # Positional args: type, project_id, device_id, data, link_id, engagement_time, timestamp, event_name, session_id, tags
    assert_equal "checkout", sidekiq_args[7]
    assert_equal "sess-456", sidekiq_args[8]
    assert_equal ["purchase"], sidekiq_args[9]
  end

  test "frozen_ch_fields folds the sdk event id into the frozen identity" do
    args = [Grovs::Events::APP_OPEN, 7, 11, nil, Time.utc(2026, 8, 6, 12, 0, 0), "", "sess-1", 0, nil]
    without = EventIngestionService.frozen_ch_fields(*args)
    with_a  = EventIngestionService.frozen_ch_fields(*args, sdk_event_id: "uuid-a")
    with_b  = EventIngestionService.frozen_ch_fields(*args, sdk_event_id: "uuid-b")

    assert_not_equal without[:event_id], with_a[:event_id]
    assert_not_equal with_a[:event_id], with_b[:event_id]
    assert_match(/\A[a-f0-9]{32}\z/, with_a[:event_id])
  end

  test "frozen_ch_fields ignores a blank or non-scalar sdk event id" do
    args = [Grovs::Events::APP_OPEN, 7, 11, nil, Time.utc(2026, 8, 6, 12, 0, 0), "", "sess-1", 0, nil]
    baseline = EventIngestionService.frozen_ch_fields(*args)

    assert_equal baseline[:event_id], EventIngestionService.frozen_ch_fields(*args, sdk_event_id: "  ")[:event_id]
    assert_equal baseline[:event_id], EventIngestionService.frozen_ch_fields(*args, sdk_event_id: { "a" => "b" })[:event_id]
  end

  private

  # Create a fresh device+visitor pair with a DB-only visitor lookup.
  # Parallel test workers share Redis but have separate test databases with
  # overlapping auto-increment IDs. This causes Redis cache key collisions:
  # Worker A caches visitor for (project_id=1, device_id=100) from DB-0,
  # Worker B creates device_id=100 in DB-1 and gets the wrong cached visitor.
  # Fix: override visitor_for_project_id to bypass Redis entirely.
  def create_fresh_device_and_visitor(platform)
    device = Device.create!(
      platform: platform,
      user_agent: "Referral-Test/#{SecureRandom.hex(4)}",
      ip: "#{rand(1..254)}.#{rand(0..254)}.#{rand(0..254)}.#{rand(1..254)}",
      remote_ip: "#{rand(1..254)}.#{rand(0..254)}.#{rand(0..254)}.#{rand(1..254)}"
    )
    visitor = Visitor.create!(project: @project, device: device, web_visitor: false)
    # Bypass Redis cache — go straight to DB (transaction-isolated per worker).
    device.define_singleton_method(:visitor_for_project_id) do |project_id|
      Visitor.includes(:device).find_by(project_id: project_id, device_id: id)
    end
    [device, visitor]
  end
end

class EventIngestionDropMetricTest < ActiveSupport::TestCase
  fixtures :instances, :projects, :devices, :visitors

  setup do
    @project = projects(:one)
    @device = devices(:ios_device)
  end

  test "emits events.dropped metric when every fallback path fails" do
    dropped = []
    Grovs::Metrics.stub(:increment, ->(name, **opts) { dropped << [name, opts] }) do
      # Force Redis enqueue, Sidekiq, and the sync path to all fail.
      REDIS.stub(:lpush, ->(*) { raise Redis::BaseError, "redis down" }) do
        LogEventJob.stub(:perform_async, ->(*) { raise Redis::BaseError, "sidekiq down" }) do
          EventIngestionService.stub(:log_event_without_view_duplicates, ->(*, **) { raise "db down" }) do
            EventIngestionService.log_async("app_open", @project, @device, nil, nil)
          end
        end
      end
    end

    assert_equal 1, dropped.size, "a dropped event must emit exactly one metric"
    assert_equal "events.dropped", dropped[0][0]
    assert_equal "app_open", dropped[0][1][:tags][:event_type]
  end

  test "no drop metric on the happy path" do
    emitted = []
    Grovs::Metrics.stub(:increment, ->(name, **) { emitted << name }) do
      EventIngestionService.log_async("app_open", @project, @device, nil, nil)
    end
    assert_not_includes emitted, "events.dropped"
  end
end

# Regression: repeat last-visit upsert must refresh updated_at (merge picks by recency).
class EventIngestionVisitorLastVisitRecencyTest < ActiveSupport::TestCase
  fixtures :instances, :projects, :devices, :visitors, :domains, :links, :redirect_configs

  test "repeat last-visit upsert refreshes both link_id and updated_at" do
    project = projects(:one)
    device  = devices(:ios_device)
    visitor = device.visitor_for_project_id(project.id)
    l1 = links(:basic_link)
    l2 = links(:second_link)
    VisitorLastVisit.where(project_id: project.id, visitor_id: visitor.id).delete_all

    EventIngestionService.send(:update_visitor_last_visit, project, device, l1)
    first = VisitorLastVisit.find_by(project_id: project.id, visitor_id: visitor.id)
    ts1 = first.updated_at
    assert_equal l1.id, first.link_id
    sleep 1.1

    EventIngestionService.send(:update_visitor_last_visit, project, device, l2)
    second = VisitorLastVisit.find_by(project_id: project.id, visitor_id: visitor.id)

    assert_equal l2.id, second.link_id, "link must update to the newer interaction"
    assert second.updated_at > ts1,
      "updated_at must refresh so the merge recency comparison stays correct"
  end
end
