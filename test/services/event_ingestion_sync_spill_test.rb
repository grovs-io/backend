# frozen_string_literal: true

require "test_helper"

class EventIngestionSyncSpillTest < ActiveSupport::TestCase
  include ClickhouseTestHelper

  fixtures :instances, :projects, :devices, :visitors, :domains, :links, :redirect_configs, :campaigns

  setup do
    @project = projects(:one)
    @device = devices(:ios_device)
    @device.update_columns(vendor: "spill-vendor", app_version: "3.0.0", build: "9001")
    @visitor = visitors(:ios_visitor)
    @visitor.send(:clear_cache)
    @link = links(:basic_link)
    @data = { "source" => "spill" }

    @original_write_enabled = Rails.application.config.clickhouse_write_enabled
    Rails.application.config.clickhouse_write_enabled = true
    ClickhouseEventSpill.delete_all
  end

  teardown do
    Rails.application.config.clickhouse_write_enabled = @original_write_enabled
  end

  def log_async_via_sync_fallback(type, device: @device, link: @link, data: @data, **kwargs)
    # The sleep separates enqueue from save, so a path that re-stamps created_at is detectable.
    lpush = lambda do |_key, payload|
      @lpush_payload = payload
      sleep 0.01
      raise Redis::BaseError, "redis down"
    end

    REDIS.stub(:lpush, lpush) do
      LogEventJob.stub(:perform_async, ->(*) { raise Redis::BaseError, "sidekiq down" }) do
        EventIngestionService.log_async(type, @project, device, data, link, nil, **kwargs)
      end
    end
  end

  def attempted_payload
    JSON.parse(@lpush_payload)
  end

  test "sync fallback spills a ClickHouse row alongside the PG event" do
    assert_difference "Event.count", 1 do
      assert_difference "ClickhouseEventSpill.count", 1 do
        log_async_via_sync_fallback(Grovs::Events::OPEN)
      end
    end

    spill = ClickhouseEventSpill.last
    event = Event.order(id: :desc).first
    row = spill.ch_row.symbolize_keys

    assert_equal @project.id, spill.project_id
    assert_equal Grovs::Events::OPEN, row[:event_type]
    assert_equal @device.id, row[:device_id]
    assert_equal @visitor.id, row[:visitor_id]
    assert_equal @link.id, row[:link_id]
    assert_equal "spill-vendor", row[:vendor_id]
    assert_equal({ "source" => "spill" }, row[:properties])
    assert_equal spill.event_id, row[:event_id]
    assert_in_delta event.created_at.to_f, spill.event_created_at.to_f, 1
  end

  test "spilled event_id matches the id the batch path would have frozen" do
    frozen_at = Time.current.change(usec: 123_000)

    log_async_via_sync_fallback(Grovs::Events::CUSTOM, created_at: frozen_at,
                                                       event_name: "checkout", session_id: "sess-1")

    expected = EventIngestionService.frozen_ch_fields(
      Grovs::Events::CUSTOM, @project.id, @device.id, @link, frozen_at, "checkout", "sess-1", nil, @data
    )[:event_id]

    assert_equal expected, ClickhouseEventSpill.last.event_id
  end

  # The LPUSH may have landed before the client raised; both copies must hash alike.
  test "spilled event_id matches the failed LPUSH payload when no created_at is supplied" do
    log_async_via_sync_fallback(Grovs::Events::OPEN)

    assert_equal attempted_payload["event_id"], ClickhouseEventSpill.last.event_id
    assert_equal attempted_payload["created_at"],
                 Event.order(id: :desc).first.created_at.iso8601(3)
  end

  test "CH-primary: spill failure rolls back the PG event and reports it dropped" do
    metrics = []

    with_clickhouse_primary do
      assert_no_difference "Event.count" do
        assert_no_difference "ClickhouseEventSpill.count" do
          Grovs::Metrics.stub(:increment, ->(name, **opts) { metrics << [name, opts] }) do
            ClickhouseSpillRepository.stub(:store, ->(*) { raise "spill table down" }) do
              log_async_via_sync_fallback(Grovs::Events::OPEN)
            end
          end
        end
      end
    end

    assert_includes metrics.map(&:first), "events.dropped"
  end

  # PG is the source of truth outside primary mode — a mirror failure must not destroy it.
  test "dual-write: spill failure keeps the PG event and only reports the mirror failure" do
    metrics = []

    assert_difference "Event.count", 1 do
      Grovs::Metrics.stub(:increment, ->(name, **opts) { metrics << [name, opts] }) do
        ClickhouseSpillRepository.stub(:store, ->(*) { raise ActiveRecord::StatementInvalid, "spill table down" }) do
          log_async_via_sync_fallback(Grovs::Events::OPEN)
        end
      end
    end

    assert_includes metrics.map(&:first), "clickhouse.spill.sync_failed"
    assert_not_includes metrics.map(&:first), "events.dropped"
  end

  # Enrichment runs before the txn — a CH-side failure there must not destroy the PG event either.
  test "dual-write: row build failure keeps the PG event and only reports the mirror failure" do
    metrics = []

    assert_difference "Event.count", 1 do
      assert_no_difference "ClickhouseEventSpill.count" do
        Grovs::Metrics.stub(:increment, ->(name, **opts) { metrics << [name, opts] }) do
          GeoipService.stub(:lookup, ->(*) { raise "geoip database unavailable" }) do
            log_async_via_sync_fallback(Grovs::Events::OPEN)
          end
        end
      end
    end

    assert_includes metrics.map(&:first), "clickhouse.spill.sync_failed"
    assert_not_includes metrics.map(&:first), "events.dropped"
  end

  # An ambiguous LPUSH may have queued the payload, so the Sidekiq replay must reuse its frozen identity
  # rather than re-derive one from a link that has since been mutated or deleted.
  test "Sidekiq fallback replays with the frozen identity, not the current link" do
    @link.update_column(:campaign_id, campaigns(:one).id)
    @link.reload
    captured = nil
    args = nil
    lpush = lambda do |_key, payload|
      captured = payload
      raise Redis::BaseError, "redis down"
    end

    REDIS.stub(:lpush, lpush) do
      LogEventJob.stub(:perform_async, ->(*a) { args = a }) do
        EventIngestionService.log_async(Grovs::Events::OPEN, @project, @device, @data, @link)
      end
    end

    attempted = JSON.parse(captured)
    # Sidekiq rejects non-JSON-native args (a symbol key raises ArgumentError past the Redis rescue).
    assert_equal args, JSON.parse(JSON.generate(args))

    Link.stub(:find_by, ->(*) { nil }) do
      LogEventJob.new.perform(*args)
    end

    spill = ClickhouseEventSpill.last
    assert_equal attempted["event_id"], spill.event_id
    assert_equal campaigns(:one).id, spill.ch_row["campaign_id"]
    assert_equal @link.visitor_id.to_i, spill.ch_row["link_visitor_id"]
  end

  # The bulk SDK path freezes identity in the payload; its Sidekiq fallback must carry it through too.
  test "bulk enqueue fallback forwards the payload's frozen identity to Sidekiq" do
    payload = {
      type: Grovs::Events::OPEN, project_id: @project.id, device_id: @device.id, data: @data,
      link_id: @link.id, engagement_time: nil, created_at: Time.current.iso8601(3),
      event_name: "", session_id: "", tags: [],
      event_id: "frozen-bulk-id", campaign_id: 77, sdk_generated: true, link_visitor_id: 5
    }
    args = nil

    REDIS.stub(:lpush, ->(*) { raise Redis::BaseError, "redis down" }) do
      LogEventJob.stub(:perform_async, ->(*a) { args = a }) do
        EventIngestionService.enqueue_events([payload])
      end
    end

    assert_equal({ "event_id" => "frozen-bulk-id", "link_id" => @link.id, "campaign_id" => 77,
                   "sdk_generated" => true, "link_visitor_id" => 5 }, args.last)
    assert_equal args, JSON.parse(JSON.generate(args))
  end

  # Sidekiq 7 enqueues over redis-client, so its outage is not a Redis::BaseError.
  test "a redis-client failure from Sidekiq still falls through to inline ingestion" do
    assert_difference "Event.count", 1 do
      REDIS.stub(:lpush, ->(*) { raise Redis::BaseError, "redis down" }) do
        LogEventJob.stub(:perform_async, ->(*) { raise RedisClient::CannotConnectError, "sidekiq redis down" }) do
          EventIngestionService.log_async(Grovs::Events::OPEN, @project, @device, @data, @link)
        end
      end
    end
  end

  # The frozen event_id encodes the original link, so the row must not claim a different one.
  test "a deleted link keeps the frozen link_id on the replayed ClickHouse row" do
    captured = nil
    args = nil
    lpush = lambda do |_key, payload|
      captured = payload
      raise Redis::BaseError, "redis down"
    end

    REDIS.stub(:lpush, lpush) do
      LogEventJob.stub(:perform_async, ->(*a) { args = a }) do
        EventIngestionService.log_async(Grovs::Events::OPEN, @project, @device, @data, @link)
      end
    end

    Link.stub(:find_by, ->(*) { nil }) do
      LogEventJob.new.perform(*args)
    end

    assert_equal JSON.parse(captured)["link_id"], ClickhouseEventSpill.last.ch_row["link_id"]
  end

  # The install falls absent keys back to the link, so the referral derived from it must too.
  test "referral inherits link-resolved attribution when the payload froze none" do
    @link.update_columns(campaign_id: campaigns(:one).id, visitor_id: visitors(:ios_visitor).id)
    @link.reload
    normalized = EventIngestionService.normalize_ch_meta({ event_id: "install-id" }, @link)
    referral = EventIngestionService.referral_ch_meta(normalized)

    assert_equal campaigns(:one).id, normalized[:campaign_id]
    assert_equal visitors(:ios_visitor).id, referral[:link_visitor_id]
    assert_not_includes referral.keys, :link_id
  end

  # An older payload never froze these keys; inventing them would read as deliberate organic attribution.
  test "payload_ch_meta keeps only the keys the payload actually froze" do
    meta = EventIngestionService.send(:payload_ch_meta, { "event_id" => "abc", "campaign_id" => nil })

    assert_equal %i[event_id campaign_id], meta.keys
    assert_nil meta[:campaign_id]
  end

  # Enrichment failure is not a CH-storage failure, so even in primary the PG row must survive.
  test "CH-primary: row build failure keeps the PG event instead of dropping it" do
    metrics = []

    with_clickhouse_primary do
      assert_difference "Event.count", 1 do
        assert_no_difference "ClickhouseEventSpill.count" do
          Grovs::Metrics.stub(:increment, ->(name, **opts) { metrics << [name, opts] }) do
            GeoipService.stub(:lookup, ->(*) { raise "geoip database unavailable" }) do
              log_async_via_sync_fallback(Grovs::Events::OPEN)
            end
          end
        end
      end
    end

    assert_includes metrics.map(&:first), "clickhouse.spill.sync_failed"
    assert_not_includes metrics.map(&:first), "events.dropped"
  end

  # An ambient-transaction caller must not be able to steer stats by mutating the returned event.
  test "post-commit dispatch reloads and ignores a caller's uncommitted edits" do
    dispatched = []
    original = EventStatDispatchService.method(:call_normal_event)
    record = lambda do |event|
      dispatched << event.event
      original.call(event)
    end
    event = nil

    EventStatDispatchService.stub(:call_normal_event, record) do
      ActiveRecord::Base.transaction do
        event = log_async_via_sync_fallback(Grovs::Events::OPEN)
        event.event = Grovs::Events::INSTALL
      end
    end

    assert_equal [Grovs::Events::OPEN], dispatched
    assert_equal Grovs::Events::OPEN, event.reload.event
  end

  test "visitorless event is not spilled with a zero visitor_id" do
    orphan = Device.create!(platform: "ios", user_agent: "Spill/1.0", ip: "10.9.9.9", remote_ip: "10.9.9.9")
    # Parallel workers share Redis and fixture ids repeat, so force the "no visitor" answer.
    orphan.define_singleton_method(:visitor_for_project_id) { |_project_id| nil }
    metrics = []

    assert_difference "Event.count", 1 do
      assert_no_difference "ClickhouseEventSpill.count" do
        Grovs::Metrics.stub(:increment, ->(name, **opts) { metrics << [name, opts] }) do
          log_async_via_sync_fallback(Grovs::Events::APP_OPEN, device: orphan, link: nil)
        end
      end
    end

    assert_includes metrics.map(&:first), "events.sync_spill_visitorless"
  end

  # Pins the two row shapes together: a new key read by the CH builder must exist here too.
  test "sync_pg_row supplies every batch pg_row key except the PG-only insert columns" do
    batch_row = BatchEventProcessorJob.new.send(
      :build_event_row,
      { type: Grovs::Events::OPEN, project_id: @project.id, device_id: @device.id,
        occurred_at: Time.current, data: nil, engagement_time: nil },
      @project, @device, @link
    )
    event = Event.new(event: Grovs::Events::OPEN, project: @project, device: @device,
                      link: @link, created_at: Time.current)
    sync_keys = EventIngestionService.send(:sync_pg_row, event, {}).keys

    assert_empty batch_row.keys - sync_keys - %i[processed updated_at]
  end

  test "no spill when ClickHouse writes are disabled" do
    Rails.application.config.clickhouse_write_enabled = false

    assert_difference "Event.count", 1 do
      assert_no_difference "ClickhouseEventSpill.count" do
        log_async_via_sync_fallback(Grovs::Events::OPEN)
      end
    end
  end

  test "deduped VIEW does not spill a second row" do
    assert_difference "ClickhouseEventSpill.count", 1 do
      log_async_via_sync_fallback(Grovs::Events::VIEW)
    end

    assert_no_difference "ClickhouseEventSpill.count" do
      log_async_via_sync_fallback(Grovs::Events::VIEW)
    end
  end

  test "referral USER_REFERRED event is spilled too" do
    installer, referrer, referrer_visitor = referral_setup

    assert_difference "ClickhouseEventSpill.count", 2 do
      log_async_via_sync_fallback(Grovs::Events::INSTALL, device: installer)
    end

    rows = ClickhouseEventSpill.all.index_by { |s| s.ch_row["event_type"] }
    assert_equal [Grovs::Events::INSTALL, Grovs::Events::USER_REFERRED].sort, rows.keys.sort

    referred = rows[Grovs::Events::USER_REFERRED].ch_row
    assert_equal referrer.id, referred["device_id"]
    assert_equal referrer_visitor.id, referred["visitor_id"]
    assert_equal "android", referred["platform"]
    assert_equal rows[Grovs::Events::INSTALL].ch_row["created_at"], referred["created_at"]
  end

  # Must equal what the batch path derives, or a replay lands a conflicting second row.
  test "spilled USER_REFERRED inherits the install identity and attribution" do
    installer, = referral_setup
    @link.update_column(:campaign_id, campaigns(:one).id)
    @link.reload

    log_async_via_sync_fallback(Grovs::Events::INSTALL, device: installer)

    install_id = attempted_payload["event_id"]
    referred = ClickhouseEventSpill.find_by(event_id: Digest::MD5.hexdigest("#{install_id}:user_referred"))

    assert_not_nil referred, "USER_REFERRED id must derive from the causal install's frozen id"
    assert_equal Grovs::Events::USER_REFERRED, referred.ch_row["event_type"]
    assert_equal @link.campaign_id, referred.ch_row["campaign_id"]
    assert_equal @link.visitor_id, referred.ch_row["link_visitor_id"]
    assert_equal 1, referred.ch_row["sdk_generated"] if @link.sdk_generated
  end

  # process_event swallows DB errors, so dispatching mid-transaction would poison the pending COMMIT —
  # including a caller's ambient transaction, which log's own block would merely join.
  test "stats are dispatched only once the outermost transaction has committed" do
    installer, = referral_setup
    dispatched = []
    original = EventStatDispatchService.method(:call_normal_event)
    record = lambda do |event|
      dispatched << event.event
      original.call(event)
    end

    EventStatDispatchService.stub(:call_normal_event, record) do
      ActiveRecord::Base.transaction do
        log_async_via_sync_fallback(Grovs::Events::INSTALL, device: installer)
        assert_empty dispatched, "stats dispatched while the caller's transaction was still open"
      end
    end

    assert_equal [Grovs::Events::INSTALL, Grovs::Events::USER_REFERRED], dispatched
  end

  private

  def referral_setup
    installer = Device.create!(platform: "ios", user_agent: "Spill/1.0", ip: "10.1.1.1", remote_ip: "10.1.1.1")
    Visitor.create!(project: @project, device: installer, web_visitor: false)
    referrer = Device.create!(platform: "android", user_agent: "Spill/1.0", ip: "10.1.1.2", remote_ip: "10.1.1.2")
    referrer_visitor = Visitor.create!(project: @project, device: referrer, web_visitor: false)
    @link.update_column(:visitor_id, referrer_visitor.id)
    @link.reload
    [installer, referrer, referrer_visitor]
  end
end
