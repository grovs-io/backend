# frozen_string_literal: true

require "test_helper"

class ClickhouseWriteServiceTest < ActiveSupport::TestCase
  include ClickhouseTestHelper

  setup do
    skip_unless_clickhouse!
  end

  # --- insert_canonical_events ---

  # Full row matching what build_clickhouse_row actually produces.
  # Catches type errors (nil JSON, wrong array type, Time format) that
  # a minimal row with 5 fields would miss.
  test "insert_canonical_events writes a full row to ClickHouse" do
    with_clickhouse_enabled do
      now = Time.current
      rows = [{
        project_id: 1,
        event_type: "VIEW",
        device_id: 100,
        visitor_id: 200,
        link_id: 300,
        inviter_id: 400,
        campaign_id: 500,
        platform: "ios",
        app_version: "2.1.0",
        build: "2026031901",
        vendor_id: "test-vendor-001",
        device_model: "iPhone 15 Pro",
        os: "iOS",
        os_version: "17.4",
        timezone: "America/New_York",
        language: "en",
        country: "US",
        city: "New York",
        tracking_source: "email",
        tracking_medium: "newsletter",
        tracking_campaign: "spring2026",
        ads_platform: "",
        link_tags: %w[promo social],
        sdk_identifier: "user_abc123",
        sdk_attributes: { "plan" => "premium", "age_group" => "25-34" },
        engagement_time: 4200,
        properties: { "screen" => "home", "tab_index" => 2 },
        tags: %w[organic mobile],
        ip: "192.168.1.1",
        remote_ip: "10.0.0.1",
        path: "test-path",
        created_at: now
      }]

      result = ClickhouseWriteService.insert_canonical_events(rows)
      assert_equal true, result

      row = ch_select_events(1, columns: %w[
        event_type device_id visitor_id link_id platform device_model
        os os_version language country city tracking_source
        sdk_identifier sdk_attributes engagement_time properties
        link_tags ip remote_ip path
      ]).first

      assert_equal "VIEW", row['event_type']
      assert_equal 100, row['device_id']
      assert_equal 200, row['visitor_id']
      assert_equal 300, row['link_id']
      assert_equal "ios", row['platform']
      assert_equal "iPhone 15 Pro", row['device_model']
      assert_equal "iOS", row['os']
      assert_equal "17.4", row['os_version']
      assert_equal "en", row['language']
      assert_equal "US", row['country']
      assert_equal "New York", row['city']
      assert_equal "email", row['tracking_source']
      assert_equal "user_abc123", row['sdk_identifier']
      assert_equal({ "plan" => "premium", "age_group" => "25-34" }, row['sdk_attributes'])
      assert_equal 4200, row['engagement_time']
      assert_equal({ "screen" => "home", "tab_index" => 2 }, row['properties'])
      assert_equal %w[promo social], row['link_tags']
      assert_equal "192.168.1.1", row['ip']
      assert_equal "10.0.0.1", row['remote_ip']
      assert_equal "test-path", row['path']
    end
  end

  test "insert_canonical_events is a no-op when disabled" do
    with_clickhouse_disabled do
      rows = [{ project_id: 1, event_type: "VIEW", created_at: Time.current }]
      result = ClickhouseWriteService.insert_canonical_events(rows)
      assert_equal true, result

      count = ch_event_count(1)
      assert_equal 0, count
    end
  end

  test "insert_canonical_events returns true for empty array" do
    with_clickhouse_enabled do
      result = ClickhouseWriteService.insert_canonical_events([])
      assert_equal true, result
    end
  end

  test "insert_canonical_events does not raise on error" do
    with_clickhouse_enabled do
      # Intentionally pass bad data — a missing required field won't raise,
      # but we can force an error by stubbing the connection.
      Clickhouse.stub(:with, ->(&_blk) { raise ClickHouse::DbException, "test error" }) do
        result = ClickhouseWriteService.insert_canonical_events([{ project_id: 1 }])
        assert_equal false, result
      end
    end
  end

  test "insert_canonical_events logs failure on error" do
    with_clickhouse_enabled do
      logged = false
      logger_stub = lambda do |msg|
        logged = true if msg.to_s.include?("ClickhouseWriteService")
      end

      Rails.logger.stub(:error, logger_stub) do
        Clickhouse.stub(:with, ->(&_blk) { raise ClickHouse::DbException, "test error" }) do
          ClickhouseWriteService.insert_canonical_events([{ project_id: 1 }])
        end
      end

      assert logged, "Failure should be logged"
    end
  end

  # --- insert_purchase_events ---

  test "insert_purchase_events writes a full row to ClickHouse" do
    with_clickhouse_enabled do
      now = Time.current
      rows = [{
        project_id: 1,
        event_type: "BUY",
        purchase_type: "subscription",
        product_id: "com.app.premium",
        usd_price_cents: 999,
        currency: "USD",
        quantity: 1,
        transaction_id: "txn_123",
        original_transaction_id: "txn_orig_100",
        store_source: "apple",
        device_id: 100,
        link_id: 200,
        visitor_id: 300,
        purchase_date: now,
        created_at: now
      }]

      result = ClickhouseWriteService.insert_purchase_events(rows)
      assert_equal true, result

      row = Clickhouse.with do |conn|
        conn.select_one("SELECT * FROM purchase_events WHERE project_id = 1 AND transaction_id = 'txn_123'")
      end

      assert_equal "BUY", row['event_type']
      assert_equal "subscription", row['purchase_type']
      assert_equal "com.app.premium", row['product_id']
      assert_equal 999, row['usd_price_cents']
      assert_equal "USD", row['currency']
      assert_equal "apple", row['store_source']
      assert_equal 100, row['device_id']
    end
  end

  test "insert_purchase_events does not raise on error" do
    with_clickhouse_enabled do
      Clickhouse.stub(:with, ->(&_blk) { raise ClickHouse::DbException, "test error" }) do
        result = ClickhouseWriteService.insert_purchase_events([{ project_id: 1 }])
        assert_equal false, result
      end
    end
  end

  test "insert_purchase_events logs failure on error" do
    with_clickhouse_enabled do
      logged = false
      logger_stub = lambda do |msg|
        logged = true if msg.to_s.include?("ClickhouseWriteService")
      end

      Rails.logger.stub(:error, logger_stub) do
        Clickhouse.stub(:with, ->(&_blk) { raise ClickHouse::DbException, "test error" }) do
          ClickhouseWriteService.insert_purchase_events([{ project_id: 1 }])
        end
      end

      assert logged, "Failure should be logged"
    end
  end

  # --- upsert_user_profile ---

  test "upsert_user_profile writes a full row to ClickHouse" do
    with_clickhouse_enabled do
      now = Time.current
      row = {
        project_id: 1,
        visitor_id: 42,
        sdk_identifier: "user_abc",
        properties: { "plan" => "premium", "level" => 5 },
        first_seen: now - 30.days,
        last_seen: now,
        country: "DE",
        platform: "android",
        inviter_id: 99
      }

      result = ClickhouseWriteService.upsert_user_profile(row)
      assert_equal true, result

      profile = Clickhouse.with do |conn|
        conn.select_one("SELECT * FROM user_profiles WHERE project_id = 1 AND visitor_id = 42")
      end

      assert_equal "user_abc", profile['sdk_identifier']
      assert_equal({ "plan" => "premium", "level" => 5 }, profile['properties'])
      assert_equal "DE", profile['country']
      assert_equal "android", profile['platform']
      assert_equal 99, profile['inviter_id']
    end
  end

  test "upsert_user_profiles batch-inserts multiple rows" do
    with_clickhouse_enabled do
      now = Time.current
      rows = [
        {
          project_id: 1, visitor_id: 100,
          sdk_identifier: "user_a", properties: { "plan" => "free" },
          first_seen: now - 10.days, last_seen: now,
          country: "US", platform: "ios", inviter_id: 0
        },
        {
          project_id: 1, visitor_id: 200,
          sdk_identifier: "user_b", properties: { "plan" => "premium" },
          first_seen: now - 5.days, last_seen: now,
          country: "GB", platform: "android", inviter_id: 100
        },
        {
          project_id: 2, visitor_id: 300,
          sdk_identifier: "user_c", properties: {},
          first_seen: now - 1.day, last_seen: now,
          country: "JP", platform: "web", inviter_id: 0
        }
      ]

      result = ClickhouseWriteService.upsert_user_profiles(rows)
      assert_equal true, result

      count = Clickhouse.with do |conn|
        conn.select_value("SELECT COUNT(*) FROM user_profiles WHERE visitor_id IN (100, 200, 300)")
      end
      assert_equal 3, count, "All 3 profiles should be inserted"

      # Verify each row landed with correct data
      profile_a = Clickhouse.with { |conn| conn.select_one("SELECT * FROM user_profiles WHERE visitor_id = 100") }
      assert_equal "user_a", profile_a['sdk_identifier']
      assert_equal "US", profile_a['country']
      assert_equal "ios", profile_a['platform']

      profile_b = Clickhouse.with { |conn| conn.select_one("SELECT * FROM user_profiles WHERE visitor_id = 200") }
      assert_equal "user_b", profile_b['sdk_identifier']
      assert_equal "GB", profile_b['country']
      assert_equal 100, profile_b['inviter_id']

      profile_c = Clickhouse.with { |conn| conn.select_one("SELECT * FROM user_profiles WHERE visitor_id = 300") }
      assert_equal "user_c", profile_c['sdk_identifier']
      assert_equal 2, profile_c['project_id']
    end
  end

  private

  def with_clickhouse_enabled
    original = Rails.application.config.clickhouse_write_enabled
    Rails.application.config.clickhouse_write_enabled = true
    yield
  ensure
    Rails.application.config.clickhouse_write_enabled = original
  end

  # --- generate_event_id ---

  test "generate_event_id produces deterministic id from event attributes" do
    id1 = ClickhouseWriteService.generate_event_id(
      project_id: 1, device_id: 100, event_type: "VIEW",
      created_at: Time.utc(2026, 5, 7, 12, 0, 0, 500_000), event_name: "", session_id: "", link_id: 0
    )
    id2 = ClickhouseWriteService.generate_event_id(
      project_id: 1, device_id: 100, event_type: "VIEW",
      created_at: Time.utc(2026, 5, 7, 12, 0, 0, 500_000), event_name: "", session_id: "", link_id: 0
    )
    id3 = ClickhouseWriteService.generate_event_id(
      project_id: 1, device_id: 100, event_type: "OPEN",
      created_at: Time.utc(2026, 5, 7, 12, 0, 0, 500_000), event_name: "", session_id: "", link_id: 0
    )

    assert_equal id1, id2, "Same inputs must produce same event_id"
    assert_not_equal id1, id3, "Different event_type must produce different event_id"
    assert_match(/\A[a-f0-9]{32}\z/, id1, "event_id must be a 32-char hex string (MD5)")
  end

  test "generate_event_id distinguishes events with different link_id" do
    ts = Time.utc(2026, 5, 7, 12, 0, 0, 500_000)

    id1 = ClickhouseWriteService.generate_event_id(
      project_id: 1, device_id: 100, event_type: "OPEN",
      created_at: ts, event_name: "", session_id: "", link_id: 10
    )
    id2 = ClickhouseWriteService.generate_event_id(
      project_id: 1, device_id: 100, event_type: "OPEN",
      created_at: ts, event_name: "", session_id: "", link_id: 20
    )

    assert_not_equal id1, id2, "Same event at same ms for different links must produce different event_id"
  end

  test "generate_event_id distinguishes millisecond-precision timestamps" do
    t1 = Time.utc(2026, 5, 7, 12, 0, 0, 0)
    t2 = Time.utc(2026, 5, 7, 12, 0, 0, 1_000) # 1ms later

    id1 = ClickhouseWriteService.generate_event_id(
      project_id: 1, device_id: 100, event_type: "VIEW", created_at: t1, event_name: "", session_id: "", link_id: 0
    )
    id2 = ClickhouseWriteService.generate_event_id(
      project_id: 1, device_id: 100, event_type: "VIEW", created_at: t2, event_name: "", session_id: "", link_id: 0
    )

    assert_not_equal id1, id2, "1ms difference must produce different event_id"
  end

  test "generate_event_id distinguishes same-ms events with different engagement_time" do
    ts = Time.utc(2026, 5, 7, 12, 0, 0, 500_000)
    id1 = ClickhouseWriteService.generate_event_id(
      project_id: 1, device_id: 100, event_type: "TIME_SPENT",
      created_at: ts, event_name: "", session_id: "", link_id: 0, engagement_time: 10
    )
    id2 = ClickhouseWriteService.generate_event_id(
      project_id: 1, device_id: 100, event_type: "TIME_SPENT",
      created_at: ts, event_name: "", session_id: "", link_id: 0, engagement_time: 20
    )
    assert_not_equal id1, id2, "Same-ms time_spent with different durations must not collapse"
  end

  test "generate_event_id distinguishes same-ms custom events with different properties" do
    ts = Time.utc(2026, 5, 7, 12, 0, 0, 500_000)
    base = { project_id: 1, device_id: 100, event_type: "custom",
             created_at: ts, event_name: "purchase", session_id: "s1", link_id: 0 }

    id1 = ClickhouseWriteService.generate_event_id(**base, properties: { "step" => "1" })
    id2 = ClickhouseWriteService.generate_event_id(**base, properties: { "step" => "2" })

    assert_not_equal id1, id2, "Same-ms custom events with different properties must not collapse"
  end

  test "generate_event_id properties digest ignores key order, key type, and input form" do
    ts = Time.utc(2026, 5, 7, 12, 0, 0, 500_000)
    base = { project_id: 1, device_id: 100, event_type: "custom",
             created_at: ts, event_name: "purchase", session_id: "s1", link_id: 0 }

    id_hash    = ClickhouseWriteService.generate_event_id(**base, properties: { "b" => "2", "a" => "1" })
    id_symbols = ClickhouseWriteService.generate_event_id(**base, properties: { a: "1", b: "2" })
    id_json    = ClickhouseWriteService.generate_event_id(**base, properties: '{"a":"1","b":"2"}')

    assert_equal id_hash, id_symbols, "key order/type must not change the id"
    assert_equal id_hash, id_json, "String-JSON and Hash forms must hash identically"
  end

  test "generate_event_id without properties keeps the legacy id" do
    ts = Time.utc(2026, 5, 7, 12, 0, 0, 500_000)
    base = { project_id: 1, device_id: 100, event_type: "custom",
             created_at: ts, event_name: "purchase", session_id: "s1", link_id: 0 }

    legacy = ClickhouseWriteService.generate_event_id(**base)

    assert_equal legacy, ClickhouseWriteService.generate_event_id(**base, properties: nil)
    assert_equal legacy, ClickhouseWriteService.generate_event_id(**base, properties: {})
  end

  test "generate_event_id caps properties the same way the CH row does" do
    ts = Time.utc(2026, 5, 7, 12, 0, 0, 500_000)
    base = { project_id: 1, device_id: 100, event_type: "custom",
             created_at: ts, event_name: "big", session_id: "s1", link_id: 0 }
    max = Analytics::Config::MAX_PROPERTY_KEYS_PER_EVENT
    uncapped = (1..(max + 10)).to_h { |i| ["k#{i.to_s.rjust(3, '0')}", i.to_s] }
    capped = uncapped.sort_by { |k, _| k.to_s }.first(max).to_h

    id_uncapped = ClickhouseWriteService.generate_event_id(**base, properties: uncapped)
    id_capped   = ClickhouseWriteService.generate_event_id(**base, properties: capped)

    assert_equal id_uncapped, id_capped,
      "freeze-time (uncapped) and row-time (capped) inputs must produce the same id"
  end

  test "generate_event_id is injective across delimiter-bearing fields" do
    ts = Time.utc(2026, 5, 7, 12, 0, 0, 500_000)
    # A naive ':'-join collides here: 'a:b' + 'c' serializes the same as 'a' + 'b:c'.
    id1 = ClickhouseWriteService.generate_event_id(
      project_id: 1, device_id: 100, event_type: "OPEN",
      created_at: ts, event_name: "a:b", session_id: "c", link_id: 0
    )
    id2 = ClickhouseWriteService.generate_event_id(
      project_id: 1, device_id: 100, event_type: "OPEN",
      created_at: ts, event_name: "a", session_id: "b:c", link_id: 0
    )
    assert_not_equal id1, id2, "Delimiter chars in free-form fields must not collide into one id"
  end

  test "generate_event_id treats an iso8601(3) string and the equivalent Time identically" do
    # The A3 backstop recomputes from the Redis payload, where created_at is an
    # iso8601(3) STRING. created_at.to_f would read '2026-...' as 2026.0 — this is
    # the regression guard that the builder parses the string back to the same ms.
    t = Time.utc(2026, 5, 7, 12, 0, 0, 123_000)
    from_time = ClickhouseWriteService.generate_event_id(
      project_id: 1, device_id: 100, event_type: "VIEW",
      created_at: t, event_name: "n", session_id: "s", link_id: 7, engagement_time: 3
    )
    from_string = ClickhouseWriteService.generate_event_id(
      project_id: 1, device_id: 100, event_type: "VIEW",
      created_at: t.iso8601(3), event_name: "n", session_id: "s", link_id: 7, engagement_time: 3
    )
    assert_equal from_time, from_string, "Backstop (iso8601 string) id must equal the frozen Time-based id"
  end

  test "generate_event_id Time/iso8601 agree at sub-millisecond precision" do
    t = Time.utc(2026, 5, 7, 12, 0, 0, 123_789) # 123.789 ms — sub-ms tail
    from_time = ClickhouseWriteService.generate_event_id(
      project_id: 1, device_id: 100, event_type: "VIEW", created_at: t, event_name: "", session_id: "", link_id: 0
    )
    from_string = ClickhouseWriteService.generate_event_id(
      project_id: 1, device_id: 100, event_type: "VIEW", created_at: t.iso8601(3), event_name: "", session_id: "", link_id: 0
    )
    assert_equal from_time, from_string, "Sub-ms Time and its iso8601(3) string must floor to the same ms"
  end

  # --- DLQ eviction ---

  test "route_to_dlq emits an eviction metric when the DLQ is already full" do
    key = ClickhouseWriteService::CANONICAL_DLQ_KEY
    max = ClickhouseWriteService::CANONICAL_DLQ_MAX
    REDIS.with do |c|
      c.del(key)
      c.pipelined { |p| max.times { p.lpush(key, "seed") } }
    end

    evictions = []
    Grovs::Metrics.stub(:increment, lambda { |name, **kw|
      evictions << kw if name == "clickhouse.dlq.evicted"
    }) do
      ClickhouseWriteService.send(:route_to_dlq, "events",
        [{ project_id: 1, created_at: Time.current }], key, RuntimeError.new("boom"))
    end

    assert_equal 1, evictions.size, "one batch must be evicted when the full list gets one more"
    assert_equal({ by: 1, tags: { table: "events" } }, evictions.first)
  ensure
    REDIS.with { |c| c.del(key) }
  end

  test "route_to_dlq emits no eviction metric when the DLQ has room" do
    key = ClickhouseWriteService::CANONICAL_DLQ_KEY
    REDIS.with { |c| c.del(key) }

    emitted = false
    Grovs::Metrics.stub(:increment, ->(name, **) { emitted = true if name == "clickhouse.dlq.evicted" }) do
      ClickhouseWriteService.send(:route_to_dlq, "events",
        [{ project_id: 1, created_at: Time.current }], key, RuntimeError.new("boom"))
    end

    assert_not emitted, "no eviction when the list is below the cap"
  ensure
    REDIS.with { |c| c.del(key) }
  end

  ID_ARGS = {
    project_id: 7, device_id: 11, event_type: "app_open", created_at: Time.utc(2026, 8, 6, 12, 0, 0),
    event_name: "", session_id: "sess-1", link_id: 3, engagement_time: 0
  }.freeze

  test "absent sdk_event_id hashes byte-identically to the legacy id" do
    legacy = ClickhouseWriteService.generate_event_id(**ID_ARGS)
    assert_equal legacy, ClickhouseWriteService.generate_event_id(**ID_ARGS, sdk_event_id: nil)
    assert_equal legacy, ClickhouseWriteService.generate_event_id(**ID_ARGS, sdk_event_id: "")
    assert_equal legacy, ClickhouseWriteService.generate_event_id(**ID_ARGS, sdk_event_id: "   ")
  end

  test "same content with different sdk_event_ids yields different ids" do
    a = ClickhouseWriteService.generate_event_id(**ID_ARGS, sdk_event_id: "uuid-a")
    b = ClickhouseWriteService.generate_event_id(**ID_ARGS, sdk_event_id: "uuid-b")
    assert_not_equal a, b
    assert_not_equal ClickhouseWriteService.generate_event_id(**ID_ARGS), a
  end

  test "sdk_event_id is stable and opaque, not case-folded" do
    id = "A1B2C3D4-0000-4000-8000-000000000000"
    assert_equal ClickhouseWriteService.generate_event_id(**ID_ARGS, sdk_event_id: id),
                 ClickhouseWriteService.generate_event_id(**ID_ARGS, sdk_event_id: id)
    assert_not_equal ClickhouseWriteService.generate_event_id(**ID_ARGS, sdk_event_id: id),
                     ClickhouseWriteService.generate_event_id(**ID_ARGS, sdk_event_id: id.downcase)
  end

  test "sdk_event_id tail cannot collide with the properties tail" do
    payload = { "k" => "v" }
    with_props = ClickhouseWriteService.generate_event_id(**ID_ARGS, properties: payload)
    as_sdk_id = ClickhouseWriteService.generate_event_id(**ID_ARGS, sdk_event_id: JSON.generate(payload))
    assert_not_equal with_props, as_sdk_id
  end

  test "normalize_sdk_event_id strips, truncates and rejects non-scalars" do
    assert_equal "abc", ClickhouseWriteService.normalize_sdk_event_id("  abc  ")
    assert_equal 255, ClickhouseWriteService.normalize_sdk_event_id("x" * 300).length
    assert_equal "42", ClickhouseWriteService.normalize_sdk_event_id(42)
    assert_nil ClickhouseWriteService.normalize_sdk_event_id(nil)
    assert_nil ClickhouseWriteService.normalize_sdk_event_id("")
    assert_nil ClickhouseWriteService.normalize_sdk_event_id({ "a" => "b" })
    assert_nil ClickhouseWriteService.normalize_sdk_event_id(%w[a b])
  end

  test "normalize_sdk_event_id is idempotent so re-normalizing never shifts the hash" do
    raw = "#{'x' * 254} y"
    once = ClickhouseWriteService.normalize_sdk_event_id(raw)

    assert_equal once, ClickhouseWriteService.normalize_sdk_event_id(once)
    assert_equal ClickhouseWriteService.generate_event_id(**ID_ARGS, sdk_event_id: raw),
                 ClickhouseWriteService.generate_event_id(**ID_ARGS, sdk_event_id: once)
  end

  test "a non-scalar sdk_event_id does not raise and falls back to content identity" do
    legacy = ClickhouseWriteService.generate_event_id(**ID_ARGS)
    assert_equal legacy, ClickhouseWriteService.generate_event_id(**ID_ARGS, sdk_event_id: { "a" => "b" })
  end

  private

  def with_clickhouse_disabled
    original = Rails.application.config.clickhouse_write_enabled
    Rails.application.config.clickhouse_write_enabled = false
    yield
  ensure
    Rails.application.config.clickhouse_write_enabled = original
  end
end
