require "test_helper"
require_relative "auth_test_helper"

class SdkEventsTest < ActionDispatch::IntegrationTest
  include AuthTestHelper

  fixtures :instances, :projects, :applications, :ios_configurations,
           :android_configurations, :devices, :visitors, :domains, :redirect_configs, :links

  setup do
    @project = projects(:one)
    @visitor = visitors(:ios_visitor)
    @link = links(:basic_link)
    @headers = sdk_headers_for(@project, @visitor, platform: "ios")
    REDIS.del("events:pending")
  end

  def last_queued_event
    raw = REDIS.with { |c| c.lindex("events:pending", 0) }
    raw && JSON.parse(raw)
  end

  # --- add_event with link + enrichment params ---

  test "add_event with link and enrichment params includes link_id, tags, session_id but not properties" do
    link = links(:basic_link)
    pushed_payload = nil

    LinksService.stub(:link_for_project_and_path, ->(_, _) { link }) do
      REDIS.stub(:lpush, ->(_, payload) { pushed_payload = payload }) do
        post "#{SDK_PREFIX}/event",
          params: {
            event: Grovs::Events::OPEN,
            path: link.path,
            properties: { screen: "detail" },
            tags: ["deep-link", "campaign"],
            session_id: "sess-link-001"
          },
          headers: @headers
      end
    end

    assert_response :ok

    parsed = JSON.parse(pushed_payload)
    assert_equal link.id, parsed["link_id"], "link_id must be present when path resolves"
    assert_equal Grovs::Events::OPEN, parsed["type"]
    assert_nil parsed["data"], "add_event must not pass properties as data"
    assert_equal ["deep-link", "campaign"], parsed["tags"]
    assert_equal "sess-link-001", parsed["session_id"]
  end

  # --- add_event with enrichment params only ---

  test "add_event passes tags and session_id but ignores properties" do
    pushed_payload = nil

    REDIS.stub(:lpush, ->(_, payload) { pushed_payload = payload }) do
      post "#{SDK_PREFIX}/event",
        params: {
          event: Grovs::Events::OPEN,
          properties: { screen: "home", tab: 2 },
          tags: ["onboarding", "beta"],
          session_id: "sess-abc-123"
        },
        headers: @headers
    end

    assert_response :ok

    parsed = JSON.parse(pushed_payload)
    assert_nil parsed["data"], "add_event must not pass properties as data"
    assert_equal "sess-abc-123", parsed["session_id"]
    assert_equal ["onboarding", "beta"], parsed["tags"]
  end

  test "add_event without enrichment params uses empty defaults" do
    pushed_payload = nil

    REDIS.stub(:lpush, ->(_, payload) { pushed_payload = payload }) do
      post "#{SDK_PREFIX}/event",
        params: { event: Grovs::Events::APP_OPEN },
        headers: @headers
    end

    assert_response :ok

    parsed = JSON.parse(pushed_payload)
    assert_equal "", parsed["event_name"]
    assert_equal "", parsed["session_id"]
    assert_equal [], parsed["tags"]
  end

  test "add_event ignores event_name even if client sends it" do
    pushed_payload = nil

    REDIS.stub(:lpush, ->(_, payload) { pushed_payload = payload }) do
      post "#{SDK_PREFIX}/event",
        params: { event: Grovs::Events::OPEN, event_name: "install" },
        headers: @headers
    end

    assert_response :ok

    parsed = JSON.parse(pushed_payload)
    assert_equal "", parsed["event_name"],
      "add_event must not pass event_name — reserved name would create ambiguity"
  end

  test "add_event with unknown event type accepts request but payload will be dropped by batch processor" do
    pushed_payload = nil

    REDIS.stub(:lpush, ->(_, payload) { pushed_payload = payload }) do
      post "#{SDK_PREFIX}/event",
        params: { event: "nonexistent_type" },
        headers: @headers
    end

    # Endpoint does not validate event type — it accepts and enqueues
    assert_response :ok

    parsed = JSON.parse(pushed_payload)
    assert_equal "nonexistent_type", parsed["type"],
      "Invalid type reaches Redis; BatchEventProcessorJob.parse_events drops it"
  end

  # --- add_custom_event ---

  test "add_custom_event with valid event_name returns 200" do
    pushed_payload = nil

    REDIS.stub(:lpush, ->(_, payload) { pushed_payload = payload }) do
      post "#{SDK_PREFIX}/event/custom",
        params: {
          event_name: "add_to_cart",
          properties: { item_id: "sku-99" },
          session_id: "sess-xyz",
          tags: ["checkout"]
        },
        headers: @headers
    end

    assert_response :ok
    json = JSON.parse(response.body)
    assert_equal "Event added", json["message"]

    parsed = JSON.parse(pushed_payload)
    assert_equal Grovs::Events::CUSTOM, parsed["type"]
    assert_equal "add_to_cart", parsed["event_name"]
    assert_equal({ "item_id" => "sku-99" }, parsed["data"])
    assert_equal "sess-xyz", parsed["session_id"]
    assert_equal ["checkout"], parsed["tags"]
  end

  test "add_custom_event passes engagement_time to Redis payload" do
    pushed_payload = nil

    REDIS.stub(:lpush, ->(_, payload) { pushed_payload = payload }) do
      post "#{SDK_PREFIX}/event/custom",
        params: { event_name: "video_watch", engagement_time: 4500 },
        headers: @headers
    end

    assert_response :ok

    parsed = JSON.parse(pushed_payload)
    assert_equal "4500", parsed["engagement_time"]
  end

  test "add_custom_event with path resolves link attribution" do
    link = links(:basic_link)
    pushed_payload = nil

    LinksService.stub(:link_for_project_and_path, ->(_, _) { link }) do
      REDIS.stub(:lpush, ->(_, payload) { pushed_payload = payload }) do
        post "#{SDK_PREFIX}/event/custom",
          params: {
            event_name: "cta_click",
            path: link.path,
            properties: { button: "buy_now" }
          },
          headers: @headers
      end
    end

    assert_response :ok

    parsed = JSON.parse(pushed_payload)
    assert_equal link.id, parsed["link_id"], "custom event must resolve link from path"
    assert_equal Grovs::Events::CUSTOM, parsed["type"]
    assert_equal "cta_click", parsed["event_name"]
    assert_equal "buy_now", parsed["data"]["button"]
  end

  test "add_custom_event without path has nil link_id" do
    pushed_payload = nil

    REDIS.stub(:lpush, ->(_, payload) { pushed_payload = payload }) do
      post "#{SDK_PREFIX}/event/custom",
        params: { event_name: "standalone_action" },
        headers: @headers
    end

    assert_response :ok

    parsed = JSON.parse(pushed_payload)
    assert_nil parsed["link_id"], "custom event without path must have nil link_id"
  end

  test "add_custom_event with screen_view uses SCREEN_VIEW event type" do
    pushed_payload = nil

    REDIS.stub(:lpush, ->(_, payload) { pushed_payload = payload }) do
      post "#{SDK_PREFIX}/event/custom",
        params: { event_name: "screen_view", properties: { screen: "settings" } },
        headers: @headers
    end

    assert_response :ok

    parsed = JSON.parse(pushed_payload)
    assert_equal Grovs::Events::SCREEN_VIEW, parsed["type"]
    assert_equal "screen_view", parsed["event_name"]
  end

  test "add_custom_event rejects reserved event_name" do
    Grovs::Events::RESERVED_EVENT_NAMES.each do |reserved|
      post "#{SDK_PREFIX}/event/custom",
        params: { event_name: reserved },
        headers: @headers

      assert_response :bad_request, "event_name '#{reserved}' should be rejected"
      json = JSON.parse(response.body)
      assert_equal "event_name is reserved", json["error"]
    end
  end

  test "add_custom_event without event_name returns 400" do
    post "#{SDK_PREFIX}/event/custom",
      params: { properties: { foo: "bar" } },
      headers: @headers

    assert_response :bad_request
    json = JSON.parse(response.body)
    assert_equal "event_name is required", json["error"]
  end

  test "add_custom_event with blank event_name returns 400" do
    post "#{SDK_PREFIX}/event/custom",
      params: { event_name: "" },
      headers: @headers

    assert_response :bad_request
  end

  # --- properties are not silently stripped ---

  test "properties with arbitrary keys are preserved through strong parameters" do
    pushed_payload = nil

    REDIS.stub(:lpush, ->(_, payload) { pushed_payload = payload }) do
      post "#{SDK_PREFIX}/event/custom",
        params: {
          event_name: "purchase",
          properties: {
            item_id: "sku-42",
            price: "19.99",
            currency: "USD",
            nested_key: "value"
          }
        },
        headers: @headers
    end

    assert_response :ok

    parsed = JSON.parse(pushed_payload)
    props = parsed["data"]
    assert_equal "sku-42", props["item_id"]
    assert_equal "19.99", props["price"]
    assert_equal "USD", props["currency"]
    assert_equal "value", props["nested_key"],
      "Arbitrary property keys must not be stripped by strong parameters"
  end

  # ActionController::Parameters stringifies values from form-encoded POST bodies.
  # SDKs send JSON (Content-Type: application/json) which preserves types, but
  # integration tests use form encoding by default. This documents the coercion.
  test "integer property values are stringified by Rails parameter parsing" do
    pushed_payload = nil

    REDIS.stub(:lpush, ->(_, payload) { pushed_payload = payload }) do
      post "#{SDK_PREFIX}/event/custom",
        params: { event_name: "tap", properties: { count: 5, enabled: true } },
        headers: @headers
    end

    assert_response :ok

    props = JSON.parse(pushed_payload)["data"]
    assert_equal "5", props["count"], "Integer coerced to string by Rails params"
    assert_equal "true", props["enabled"], "Boolean coerced to string by Rails params"
  end

  test "properties absent from params results in nil data" do
    pushed_payload = nil

    REDIS.stub(:lpush, ->(_, payload) { pushed_payload = payload }) do
      post "#{SDK_PREFIX}/event/custom",
        params: { event_name: "tap" },
        headers: @headers
    end

    assert_response :ok

    parsed = JSON.parse(pushed_payload)
    assert_nil parsed["data"]
  end

  # --- malicious / oversized input ---

  test "oversized event_name is truncated in Redis payload" do
    pushed_payload = nil
    huge_name = "x" * 10_000

    REDIS.stub(:lpush, ->(_, payload) { pushed_payload = payload }) do
      post "#{SDK_PREFIX}/event/custom",
        params: { event_name: huge_name },
        headers: @headers
    end

    assert_response :ok

    parsed = JSON.parse(pushed_payload)
    assert_equal Grovs::Enrichment::MAX_STRING_LENGTH, parsed["event_name"].length
  end

  test "tags array with 1000 elements is capped" do
    pushed_payload = nil
    huge_tags = (1..1000).map { |i| "tag-#{i}" }

    REDIS.stub(:lpush, ->(_, payload) { pushed_payload = payload }) do
      post "#{SDK_PREFIX}/event/custom",
        params: { event_name: "flood", tags: huge_tags },
        headers: @headers
    end

    assert_response :ok

    parsed = JSON.parse(pushed_payload)
    assert_equal Grovs::Enrichment::MAX_TAGS, parsed["tags"].size
    assert_equal "tag-1", parsed["tags"].first
  end

  test "deeply nested properties are passed through without error" do
    pushed_payload = nil
    nested = { "a" => { "b" => { "c" => { "d" => "deep" } } } }

    REDIS.stub(:lpush, ->(_, payload) { pushed_payload = payload }) do
      post "#{SDK_PREFIX}/event/custom",
        params: { event_name: "nested_test", properties: nested },
        headers: @headers
    end

    assert_response :ok

    parsed = JSON.parse(pushed_payload)
    assert_equal "deep", parsed["data"]["a"]["b"]["c"]["d"]
  end

  test "properties exceeding MAX_PROPERTIES_BYTES are dropped" do
    pushed_payload = nil
    # Build a properties hash that exceeds 8KB
    huge_props = {}
    100.times { |i| huge_props["key_#{i}"] = "v" * 100 }

    assert huge_props.to_json.bytesize > Grovs::Enrichment::MAX_PROPERTIES_BYTES,
      "Test precondition: payload must exceed limit"

    REDIS.stub(:lpush, ->(_, payload) { pushed_payload = payload }) do
      post "#{SDK_PREFIX}/event/custom",
        params: { event_name: "oversized_props", properties: huge_props },
        headers: @headers
    end

    assert_response :ok

    parsed = JSON.parse(pushed_payload)
    assert_nil parsed["data"], "Properties exceeding byte limit must be dropped"
    assert_equal "oversized_props", parsed["event_name"], "Event still recorded without properties"
  end

  test "properties just under MAX_PROPERTIES_BYTES are accepted" do
    pushed_payload = nil
    # Build a properties hash just under the limit
    props = { "k" => "x" * (Grovs::Enrichment::MAX_PROPERTIES_BYTES - 20) }

    assert props.to_json.bytesize <= Grovs::Enrichment::MAX_PROPERTIES_BYTES,
      "Test precondition: payload must be under limit"

    REDIS.stub(:lpush, ->(_, payload) { pushed_payload = payload }) do
      post "#{SDK_PREFIX}/event/custom",
        params: { event_name: "big_but_ok", properties: props },
        headers: @headers
    end

    assert_response :ok

    parsed = JSON.parse(pushed_payload)
    assert_not_nil parsed["data"], "Properties under limit must be accepted"
  end

  test "unicode and emoji in event_name and properties are preserved" do
    pushed_payload = nil

    REDIS.stub(:lpush, ->(_, payload) { pushed_payload = payload }) do
      post "#{SDK_PREFIX}/event/custom",
        params: {
          event_name: "购买_completed",
          properties: { label: "🎉 success", city: "東京" },
          tags: ["日本語", "émojis"]
        },
        headers: @headers
    end

    assert_response :ok

    parsed = JSON.parse(pushed_payload)
    assert_equal "购买_completed", parsed["event_name"]
    assert_equal "🎉 success", parsed["data"]["label"]
    assert_equal "東京", parsed["data"]["city"]
    assert_equal ["日本語", "émojis"], parsed["tags"]
  end

  test "event with link url resolves the link and queues with link_id" do
    url = "https://#{@link.domain.subdomain}.#{@link.domain.domain}/#{@link.path}"
    post "#{SDK_PREFIX}/event", params: { event: "open", link: url }, headers: @headers

    assert_response :ok
    payload = last_queued_event
    assert_equal "open", payload["type"]
    assert_equal @link.id, payload["link_id"]
  end

  test "event with path resolves the link for the project" do
    post "#{SDK_PREFIX}/event", params: { event: "open", path: @link.path }, headers: @headers

    assert_response :ok
    assert_equal @link.id, last_queued_event["link_id"]
  end

  test "event with a foreign project's link url queues without link_id" do
    other = links(:second_link)
    url = "https://#{other.domain.subdomain}.#{other.domain.domain}/#{other.path}"
    post "#{SDK_PREFIX}/event", params: { event: "open", link: url }, headers: @headers

    assert_response :ok
    assert_nil last_queued_event["link_id"], "cross-tenant link must not be attributed"
  end

  test "event with unresolvable link still queues without link_id" do
    post "#{SDK_PREFIX}/event",
      params: { event: "open", link: "https://nope.example.com/missing" }, headers: @headers

    assert_response :ok
    assert_nil last_queued_event["link_id"]
  end

  test "link resolution failure does not lose the event" do
    LinksService.stub(:link_for_url, ->(*) { raise "boom" }) do
      post "#{SDK_PREFIX}/event",
        params: { event: "open", link: "https://x.example.com/p" }, headers: @headers
    end

    assert_response :ok
    assert_equal "open", last_queued_event["type"]
  end

  test "valid created_at is honored in the queued payload" do
    ts = 2.days.ago.change(usec: 0)
    post "#{SDK_PREFIX}/event",
      params: { event: "app_open", created_at: ts.iso8601 }, headers: @headers

    assert_response :ok
    assert_in_delta ts.to_f, Time.parse(last_queued_event["created_at"]).to_f, 1.0
  end

  # A device clock years ahead sorted above every real row in the event log.
  test "a future created_at is clamped to now" do
    post "#{SDK_PREFIX}/event",
      params: { event: "app_open", created_at: 3.days.from_now.iso8601 }, headers: @headers

    assert_response :ok
    assert_in_delta Time.current.to_f, Time.parse(last_queued_event["created_at"]).to_f, 5.0
  end

  # Benign drift must stay byte-identical, or its event_id stops dedupping a replay.
  test "a created_at inside the tolerance is left untouched" do
    ts = (Time.current + 30.seconds).change(usec: 0)
    post "#{SDK_PREFIX}/event",
      params: { event: "app_open", created_at: ts.iso8601 }, headers: @headers

    assert_response :ok
    assert_in_delta ts.to_f, Time.parse(last_queued_event["created_at"]).to_f, 1.0
  end

  test "a past created_at is never clamped" do
    ts = 30.days.ago.change(usec: 0)
    post "#{SDK_PREFIX}/event",
      params: { event: "app_open", created_at: ts.iso8601 }, headers: @headers

    assert_response :ok
    assert_in_delta ts.to_f, Time.parse(last_queued_event["created_at"]).to_f, 1.0
  end

  test "unparseable created_at falls back instead of failing" do
    post "#{SDK_PREFIX}/event",
      params: { event: "app_open", created_at: "not-a-date" }, headers: @headers

    assert_response :ok
    payload = last_queued_event
    assert_in_delta Time.current.to_f, Time.parse(payload["created_at"]).to_f, 5.0
  end

  test "event with engagement_time queues it" do
    post "#{SDK_PREFIX}/event",
      params: { event: "time_spent", engagement_time: 42 }, headers: @headers

    assert_response :ok
    assert_equal "42", last_queued_event["engagement_time"].to_s
  end

  def create_provider_hosted_source_with_cached_link!
    ENV["GROVS_SELF_HOSTED"] = "true"
    # Classes that declare fixtures :migration_sources leave rows behind for later classes.
    MigrationSource.delete_all
    src = MigrationSource.create!(
      project: @project, old_host: "xyz.app.link",
      provider: Grovs::Migrations::PROVIDER_BRANCH,
      credentials: { "branch_key" => "k" },
      provider_hosted: true, extra_hosts: ["xyz-alternate.app.link"]
    )
    MigratedLink.create!(migration_source: src, old_path: "abc",
                         status: MigratedLink::STATUS_RESOLVED, link: @link)
    src
  end

  test "INSTALL with a provider-hosted migration URL resolves link_id via the migration fallback" do
    enable_migrations!
    create_provider_hosted_source_with_cached_link!

    post "#{SDK_PREFIX}/event",
      params: { event: Grovs::Events::INSTALL, link: "https://xyz-alternate.app.link/abc" },
      headers: @headers

    assert_response :ok
    assert_equal @link.id, last_queued_event["link_id"],
                 "install carrying an old-host URL must attribute via MigrationResolver"
  ensure
    disable_migrations!
  end

  test "INSTALL with a custom-scheme link never reaches the migration slug fallback" do
    enable_migrations!
    create_provider_hosted_source_with_cached_link!

    upstream_calls = 0
    FirstHitMigration.stub(:call, ->(*) { upstream_calls += 1; nil }) do
      post "#{SDK_PREFIX}/event",
        params: { event: Grovs::Events::INSTALL, link: "myapp://open/some-garbage" },
        headers: @headers
    end

    assert_response :ok
    assert_nil last_queued_event["link_id"]
    assert_equal 0, upstream_calls, "bare-slug shapes must not hit upstream from events"
  ensure
    disable_migrations!
  end

  test "OPEN with a provider-hosted migration URL does NOT use the migration fallback" do
    enable_migrations!
    create_provider_hosted_source_with_cached_link!

    post "#{SDK_PREFIX}/event",
      params: { event: Grovs::Events::OPEN, link: "https://xyz-alternate.app.link/abc" },
      headers: @headers

    assert_response :ok
    assert_nil last_queued_event["link_id"],
               "OPEN attribution flows through data_for_device_and_url, not the events fallback"
  ensure
    disable_migrations!
  end
end
