require "test_helper"

class DeliverEventDestinationJobTest < ActiveSupport::TestCase
  include ClickhouseTestHelper
  include ActionMailer::TestHelper
  include AuditTestHelper
  include EventStreamTestHelper
  fixtures :instances, :users, :instance_roles, :projects, :devices, :visitors

  setup do
    skip_unless_clickhouse!
    @project = projects(:one)
    entitle!(instances(:one))
    @dest = EventDestination.new(project: @project, name: "crm", kind: "webhook", settings: { "url" => "https://hooks.example.com/in" },
                                 batch_size: 100, concurrency: 2, event_types: %w[install app_open purchase])
    @dest.generate_signing_secret
    @dest.save!
    @dest.rewind!(to: 1.hour.ago)
    @ios = devices(:ios_device).id
  end

  teardown do
    return unless @dest

    keys = ["sidekiq:single_flight:event_destination:#{@dest.id}", EventStreamTickJob.enqueued_key(@dest.id), *EventStream::Deliverer.gap_keys(@dest.id)]
    REDIS.with { |c| c.del(*keys) }
  end

  def ok = Struct.new(:code, :body).new(200, "")

  def capture_into(posted)
    lambda do |_url, opts|
      posted << opts[:body]
      ok
    end
  end

  def seed(count, device_id: @ios, type: "app_open", at: 5.minutes.ago, prefix: device_id)
    insert_outbox_events((1..count).map do |i|
      { project_id: @project.id, event_type: type, outbox_at: at + i, event_id: "#{prefix}-#{type}-#{i}",
        device_id: device_id, visitor_id: visitors(:ios_visitor).id }
    end)
  end

  def posted_ids(posted) = posted.flat_map { |b| b.split("\n").map { |l| JSON.parse(l)["id"] } }

  test "delivers new events in order, advances the bookmark, and is idle afterwards" do
    seed(3)
    posted = []
    HTTParty.stub(:post, capture_into(posted)) do
      assert_equal :delivered, EventStream::Deliverer.new(@dest).run_once
      assert_equal "#{@ios}-app_open-3", @dest.reload.events_cursor_id
      assert_equal :idle, EventStream::Deliverer.new(@dest).run_once
    end
    assert_equal (1..3).map { |i| "#{@ios}-app_open-#{i}" }, posted_ids(posted)
    assert_equal 3, @dest.reload.delivered_count
  end

  test "event type filter drops unwanted types" do
    seed(2, type: "time_spent")
    seed(1, type: "install")
    posted = []
    HTTParty.stub(:post, capture_into(posted)) { EventStream::Deliverer.new(@dest).run_once }
    assert_equal ["install"], posted.flat_map { |b| b.split("\n").map { |l| JSON.parse(l)["type"] } }
  end

  test "different devices are sent in parallel groups, same device stays ordered in one request stream" do
    seed(2, device_id: @ios)
    seed(2, device_id: devices(:android_device).id)
    posted = []
    HTTParty.stub(:post, capture_into(posted)) { EventStream::Deliverer.new(@dest).run_once }
    per_device = posted.map { |b| b.split("\n").map { |l| JSON.parse(l).dig("device", "id") }.uniq }
    assert_equal 2, posted.size
    assert per_device.all? { |d| d.size == 1 }, "a request must never mix devices: #{per_device.inspect}"
  end

  test "a failed group stops the bookmark before its first failed event and records backoff" do
    seed(3)
    HTTParty.stub(:post, ->(*) { Struct.new(:code, :body).new(502, "bad") }) do
      assert_equal :failed, EventStream::Deliverer.new(@dest).run_once
    end
    @dest.reload
    assert_equal "", @dest.events_cursor_id
    assert_equal 1, @dest.consecutive_failures
    assert @dest.backoff_until > Time.current
    assert_match(/502/, @dest.last_error)
  end

  test "a partially accepted batch advances the bookmark to the accepted prefix only" do
    @dest.update!(batch_size: 1, concurrency: 1)
    seed(3)
    n = 0
    HTTParty.stub(:post, ->(*) { (n += 1) == 3 ? Struct.new(:code, :body).new(500, "x") : ok }) do
      assert_equal :failed, EventStream::Deliverer.new(@dest).run_once
    end
    assert_equal "#{@ios}-app_open-2", @dest.reload.events_cursor_id
    assert_equal 2, @dest.delivered_count
  end

  test "stops starting new device groups after the deadline and keeps the delivered prefix" do
    @dest.update!(concurrency: 1)
    seed(2, device_id: @ios, at: 5.minutes.ago)
    seed(2, device_id: devices(:android_device).id, at: 4.minutes.ago)
    posted = []
    slow = lambda do |_url, opts|
      sleep 0.3
      posted << opts[:body]
      ok
    end
    HTTParty.stub(:post, slow) do
      assert_equal :delivered, EventStream::Deliverer.new(@dest, deadline: Time.current + 0.1).run_once
    end
    assert_equal 1, posted.size
    @dest.reload
    assert_equal "#{@ios}-app_open-2", @dest.events_cursor_id
    assert_equal 0, @dest.consecutive_failures
  end

  test "a destination that accepts part of every batch still auto-pauses" do
    @dest.update!(batch_size: 1, concurrency: 1, failing_since: 25.hours.ago, consecutive_failures: 40)
    seed(2)
    n = 0
    HTTParty.stub(:post, ->(*) { (n += 1) == 1 ? ok : Struct.new(:code, :body).new(500, "x") }) do
      assert_emails 1 do
        assert_equal :paused, EventStream::Deliverer.new(@dest).run_once
      end
    end
    @dest.reload
    assert @dest.paused?
    assert_equal "#{@ios}-app_open-1", @dest.events_cursor_id
  end

  test "auto-pauses after 24h of failure and emails admins" do
    seed(1)
    @dest.update!(failing_since: 25.hours.ago, consecutive_failures: 40)
    HTTParty.stub(:post, ->(*) { Struct.new(:code, :body).new(500, "x") }) do
      assert_emails 1 do
        assert_equal :paused, EventStream::Deliverer.new(@dest).run_once
      end
    end
    assert @dest.reload.paused?
  end

  test "a bookmark older than retention is moved forward and the gap is emailed" do
    @dest.rewind!(to: 10.days.ago)
    HTTParty.stub(:post, ->(*) { ok }) do
      assert_emails 1 do
        EventStream::Deliverer.new(@dest).run_once
      end
    end
    assert @dest.reload.events_cursor_at > 8.days.ago
  end

  test "a bookmark kept behind retention emails the gap once a day, covering every skipped range" do
    first_from = 10.days.ago.change(usec: 0)
    suppressed_from = 9.days.ago.change(usec: 0)
    @dest.rewind!(to: first_from)
    HTTParty.stub(:post, ->(*) { ok }) do
      assert_emails 1 do
        EventStream::Deliverer.new(@dest).run_once
        @dest.reload.update!(events_cursor_at: suppressed_from)
        EventStream::Deliverer.new(@dest.reload).run_once
      end
      REDIS.with { |c| c.del(EventStream::Deliverer.gap_keys(@dest.id).first) } # the daily mark expires
      @dest.reload.update!(events_cursor_at: 8.days.ago)
      assert_emails 1 do
        EventStream::Deliverer.new(@dest.reload).run_once
      end
    end
    mails = ActionMailer::Base.deliveries.last(2).map { |m| m.text_part.body.to_s }
    assert_includes mails.first, first_from.utc.iso8601
    assert_includes mails.last, suppressed_from.utc.iso8601, "the next email starts at the first suppressed gap"
  end

  test "a held gap is still emailed once after delivery catches up" do
    held_from = 9.days.ago.change(usec: 0)
    @dest.rewind!(to: 10.days.ago)
    HTTParty.stub(:post, ->(*) { ok }) do
      assert_emails 1 do
        EventStream::Deliverer.new(@dest).run_once
        @dest.reload.update!(events_cursor_at: held_from)
        EventStream::Deliverer.new(@dest.reload).run_once
        EventStream::Deliverer.new(@dest.reload).run_once
      end
      REDIS.with { |c| c.del(EventStream::Deliverer.gap_keys(@dest.id).first) }
      assert_emails 1 do
        EventStream::Deliverer.new(@dest.reload).run_once
        REDIS.with { |c| c.del(EventStream::Deliverer.gap_keys(@dest.id).first) }
        EventStream::Deliverer.new(@dest.reload).run_once
      end
    end
    assert_includes ActionMailer::Base.deliveries.last.text_part.body.to_s, held_from.utc.iso8601
  end

  test "the cutoff comes from the ClickHouse clock, so an app clock running ahead cannot skip rows" do
    travel 1.hour do
      assert_equal :idle, EventStream::Deliverer.new(@dest).run_once
    end
    assert @dest.reload.events_cursor_at <= Time.current - 14.seconds
    assert @dest.purchases_cursor_at <= Time.current - 14.seconds
  end

  test "idle streams move to the cutoff so a quiet destination never goes stale" do
    assert_equal :idle, EventStream::Deliverer.new(@dest).run_once
    @dest.reload
    assert @dest.events_cursor_at > 1.minute.ago
    assert @dest.purchases_cursor_at > 1.minute.ago
  end

  test "a stale stream the destination does not request neither rewinds delivery nor emails" do
    @dest.update!(event_types: %w[install], events_cursor_at: 1.minute.ago, events_cursor_id: "", purchases_cursor_at: 8.days.ago)
    seed(1, type: "install", at: 3.days.ago, prefix: "old")
    HTTParty.stub(:post, ->(*) { flunk "an already-delivered event must not be replayed" }) do
      assert_emails 0 do
        assert_equal :idle, EventStream::Deliverer.new(@dest).run_once
      end
    end
    assert @dest.reload.purchases_cursor_at > 1.minute.ago
  end

  test "purchases are delivered with version-bearing ids" do
    insert_outbox_purchases([{ project_id: @project.id, event_type: "buy", transaction_id: "t1", usd_price_cents: 100, currency: "USD",
                               device_id: @ios, visitor_id: visitors(:ios_visitor).id, outbox_at: 2.minutes.ago }])
    posted = []
    HTTParty.stub(:post, capture_into(posted)) { EventStream::Deliverer.new(@dest).run_once }
    env = JSON.parse(posted.first.split("\n").first)
    assert_equal "purchase", env["type"]
    assert_equal "t1", env.dig("purchase", "transaction_id")
    assert_match(/\At1:buy:\d+\z/, @dest.reload.purchases_cursor_id)
  end

  test "analytics and purchases of one device go out in arrival order" do
    @dest.update!(concurrency: 1)
    seed(1, type: "app_open", at: 3.minutes.ago)
    insert_outbox_purchases([{ project_id: @project.id, event_type: "buy", transaction_id: "t1", usd_price_cents: 100, currency: "USD",
                               device_id: @ios, visitor_id: visitors(:ios_visitor).id, outbox_at: 2.minutes.ago }])
    seed(1, type: "install", at: 1.minute.ago)
    posted = []
    HTTParty.stub(:post, capture_into(posted)) { EventStream::Deliverer.new(@dest).run_once }
    assert_equal %w[app_open purchase install], posted.flat_map { |b| b.split("\n").map { |l| JSON.parse(l)["type"] } }
  end

  test "a bookmark moved by someone else wins over this run's older position" do
    seed(1)
    stale = EventDestination.find(@dest.id)
    @dest.rewind!(to: 2.days.ago)
    HTTParty.stub(:post, ->(*) { ok }) do
      assert_equal :stale, EventStream::Deliverer.new(stale).run_once
    end
    assert_in_delta 2.days.ago.to_i, @dest.reload.events_cursor_at.to_i, 5
  end

  test "kill switch and paused destinations do nothing" do
    seed(1)
    @dest.pause!("manual")
    assert_equal :disabled, EventStream::Deliverer.new(@dest).run_once
    @dest.resume!
    ENV["EVENT_STREAM_ENABLED"] = "false"
    assert_equal :disabled, EventStream::Deliverer.new(@dest).run_once
  ensure
    ENV.delete("EVENT_STREAM_ENABLED")
  end

  test "job is single-flight per destination" do
    seed(1)
    REDIS.with { |c| c.set("sidekiq:single_flight:event_destination:#{@dest.id}", "other", nx: true, ex: 60) }
    HTTParty.stub(:post, ->(*) { flunk "must not deliver while another run holds the lock" }) do
      DeliverEventDestinationJob.new.perform(@dest.id)
    end
    assert_equal "", @dest.reload.events_cursor_id
  end

  test "an idle destination frees its worker right away" do
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    DeliverEventDestinationJob.new.perform(@dest.id)
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 5
  end

  test "a queued job honors a backoff recorded after it was enqueued" do
    seed(1)
    @dest.update!(backoff_until: 5.minutes.from_now)
    HTTParty.stub(:post, ->(*) { flunk "must not deliver during backoff" }) do
      DeliverEventDestinationJob.new.perform(@dest.id)
    end
    assert_equal "", @dest.reload.events_cursor_id
  end

  test "tick keeps one outstanding job per destination until that job finishes" do
    enqueued = []
    DeliverEventDestinationJob.stub(:perform_async, ->(id, marker) { enqueued << [id, marker] }) do
      2.times { EventStreamTickJob.new.perform }
      assert_equal [@dest.id], enqueued.map(&:first)
      DeliverEventDestinationJob.new.perform(*enqueued.first)
      EventStreamTickJob.new.perform
    end
    assert_equal [@dest.id, @dest.id], enqueued.map(&:first)
  end

  test "an older job cannot release a newer job's queue marker" do
    key = EventStreamTickJob.enqueued_key(@dest.id)
    REDIS.with { |c| c.set(key, "newer", ex: 60) }
    DeliverEventDestinationJob.new.perform(@dest.id, "older")
    assert_equal "newer", REDIS.with { |c| c.get(key) }
  end

  test "an s3 run uploads one event date at a time, each run a single bounded PUT" do
    lake = EventDestination.new(project: @project, name: "lake", kind: "s3", event_types: %w[app_open],
                                settings: { "bucket" => "b", "region" => "eu-central-1" })
    lake.credentials_hash = { "access_key_id" => "AKIA", "secret_access_key" => "s" }
    lake.save!
    lake.rewind!(to: 1.hour.ago)
    insert_outbox_events([
      { project_id: @project.id, event_type: "app_open", event_id: "d1", device_id: @ios, visitor_id: visitors(:ios_visitor).id,
        outbox_at: 5.minutes.ago, created_at: "2026-09-14 10:00:00.000" },
      { project_id: @project.id, event_type: "app_open", event_id: "d2", device_id: @ios, visitor_id: visitors(:ios_visitor).id,
        outbox_at: 4.minutes.ago, created_at: "2026-09-15 10:00:00.000" }
    ])
    uploads = []
    client = Object.new
    client.define_singleton_method(:put_object) { |**args| uploads << args }
    EventStream::Adapters::S3.stub(:build_client, client) do
      assert_equal :delivered, EventStream::Deliverer.new(lake).run_once
      assert_equal "d1", lake.reload.events_cursor_id
      assert_equal :delivered, EventStream::Deliverer.new(lake).run_once
    end
    assert_equal %w[date=2026-09-14 date=2026-09-15], uploads.map { |u| u[:key][/date=[\d-]+/] }
  end

  def use_s3_destination
    @dest.kind = "s3"
    @dest.settings = { "bucket" => "qa", "region" => "eu-central-1" }
    @dest.credentials_hash = { "access_key_id" => "AKIA", "secret_access_key" => "secret" }
    @dest.save!
  end

  test "s3 backlog continues on the next tick after yielding its worker" do
    use_s3_destination
    travel_to Time.current.change(usec: 0) do
      seed(501, at: 1.hour.ago)
      uploads = []
      client = Object.new
      test_clock = self
      client.define_singleton_method(:put_object) do |**args|
        uploads << Zlib::GzipReader.new(StringIO.new(args[:body])).read.lines.map { |line| JSON.parse(line)["id"] }
        test_clock.travel 56.seconds if uploads.size == 1
      end
      EventStream::Adapters::S3.stub(:build_client, client) do
        DeliverEventDestinationJob.new.perform(@dest.id)
        assert_equal 500, @dest.reload.delivered_count
        assert_equal Time.current, @dest.last_attempt_at
        travel 1.minute
        enqueued = []
        DeliverEventDestinationJob.stub(:perform_async, ->(id, marker) { enqueued << [id, marker] }) do
          EventStreamTickJob.new.perform
        end
        assert_equal [@dest.id], enqueued.map(&:first), "pending S3 events must not wait another five minutes"
        DeliverEventDestinationJob.new.perform(*enqueued.first)
      end
      assert_equal 501, @dest.reload.delivered_count
      assert_equal 501, uploads.flatten.uniq.size
      assert_equal 501, uploads.flatten.size
      assert_not @dest.due?(Time.current), "a caught-up destination should resume normal batching"
      assert @dest.due?(5.minutes.from_now)
    end
  end

  test "an empty s3 destination waits five minutes before checking again" do
    use_s3_destination
    travel_to Time.current.change(usec: 0) do
      DeliverEventDestinationJob.new.perform(@dest.id)
      assert_not @dest.reload.due?(Time.current)
      assert_not @dest.due?(299.seconds.from_now)
      assert @dest.due?(5.minutes.from_now)
      assert_nil @dest.last_attempt_at
      assert_nil @dest.last_delivered_at
    end
  end

  test "s3 failures honor their backoff without adding the idle flush interval" do
    use_s3_destination
    seed(1)
    travel_to Time.current.change(usec: 0) do
      client = Object.new
      client.define_singleton_method(:put_object) { |**| raise "temporary S3 failure" }
      EventStream::Adapters::S3.stub(:build_client, client) { DeliverEventDestinationJob.new.perform(@dest.id) }
      assert_equal 1, @dest.reload.consecutive_failures
      assert_not @dest.due?(Time.current)
      assert @dest.due?(@dest.backoff_until)
      EventStream::Adapters::S3.stub(:build_client, ->(*) { flunk "queued job must honor backoff" }) do
        DeliverEventDestinationJob.new.perform(@dest.id)
      end
      assert_equal 0, @dest.reload.delivered_count
    end
  end

  test "resuming or rewinding an idle s3 destination makes it eligible again" do
    use_s3_destination
    DeliverEventDestinationJob.new.perform(@dest.id)
    @dest.reload.pause!("manual")
    assert_not @dest.due?(Time.current)
    @dest.resume!
    assert @dest.due?(Time.current)
    DeliverEventDestinationJob.new.perform(@dest.id)
    @dest.reload.rewind!(to: 10.minutes.ago)
    assert @dest.due?(Time.current)
  end

  test "s3 continuation cannot overlap another delivery worker" do
    use_s3_destination
    seed(1)
    REDIS.with { |c| c.set("sidekiq:single_flight:event_destination:#{@dest.id}", "other", ex: 60) }
    EventStream::Adapters::S3.stub(:build_client, ->(*) { flunk "another worker owns this destination" }) do
      DeliverEventDestinationJob.new.perform(@dest.id)
    end
    assert_equal 0, @dest.reload.delivered_count
    assert @dest.due?(Time.current)
  end

  test "a concurrent rewind wins over an older s3 idle result" do
    use_s3_destination
    stale = EventDestination.find(@dest.id)
    @dest.rewind!(to: 10.minutes.ago)
    cursor = @dest.events_cursor_at
    assert_equal :stale, EventStream::Deliverer.new(stale).run_once
    assert_equal cursor, @dest.reload.events_cursor_at
    assert @dest.due?(Time.current)
  end

  test "tick skips a destination whose instance is not entitled" do
    unentitle!(instances(:one))
    enqueued = []
    DeliverEventDestinationJob.stub(:perform_async, ->(id, _marker) { enqueued << id }) { EventStreamTickJob.new.perform }
    assert_empty enqueued
    assert_nil REDIS.with { |c| c.get(EventStreamTickJob.enqueued_key(@dest.id)) }
  end

  test "tick enqueues one job per due enabled destination" do
    other = EventDestination.create!(project: @project, name: "paused", kind: "webhook", settings: { "url" => "https://x.example.com" }, status: "paused")
    enqueued = []
    DeliverEventDestinationJob.stub(:perform_async, ->(id, _marker) { enqueued << id }) { EventStreamTickJob.new.perform }
    assert_equal [@dest.id], enqueued
    assert_not_includes enqueued, other.id
  end
end
