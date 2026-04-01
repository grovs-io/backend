require "test_helper"

class EventIngestionServiceTest < ActiveSupport::TestCase
  fixtures :instances, :projects, :devices, :visitors, :domains, :links,
           :redirect_configs, :events, :visitor_last_visits

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

  test "dedup matches on device_id not project_id — cross-project VIEW is incorrectly deduped" do
    # This documents a known behavioral quirk: the dedup query filters on
    # (event, device_id, created_at) but NOT project_id. So two VIEWs from
    # the same device on different projects within 5s will dedup.
    project_two = projects(:two)
    Visitor.create!(project: project_two, device: @device, web_visitor: false)

    first = EventIngestionService.log(
      Grovs::Events::VIEW, @project, @device, @data, @link
    )

    EventStatDispatchService.stub(:call_normal_event, ->(_) {}) do
      result = EventIngestionService.log_event_without_view_duplicates(
        Grovs::Events::VIEW, project_two, @device, @data, links(:second_link)
      )

      # The second VIEW is for a DIFFERENT project, but gets deduped because
      # the query only matches on device_id. This asserts current behavior.
      assert_equal first.id, result.id,
                   "Cross-project VIEW dedup: query lacks project_id filter"
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
