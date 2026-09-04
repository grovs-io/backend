require "test_helper"
require_relative "auth_test_helper"

class SdkBatchEventsTest < ActionDispatch::IntegrationTest
  include AuthTestHelper
  include ClickhouseTestHelper

  fixtures :instances, :projects, :applications, :ios_configurations,
           :android_configurations, :devices, :visitors, :domains, :redirect_configs, :links,
           :users, :instance_roles, :campaigns

  setup do
    @project = projects(:one)
    @visitor = visitors(:ios_visitor)
    @link = links(:basic_link)
    @headers = sdk_headers_for(@project, @visitor)
  end

  # --- Phase 1: frozen event-time source capture ---

  test "batch builder freezes link source and event_id into each payload" do
    @link.update_columns(campaign_id: campaigns(:one).id, visitor_id: @visitor.id, sdk_generated: true)
    @link.send(:clear_cache) # update_columns bypasses cache invalidation; controller resolves via the model cache
    REDIS.del(BatchEventProcessorJob::REDIS_KEY)

    post "#{SDK_PREFIX}/events/batch",
      params: { events: [{ event: "app_open", path: @link.path }] },
      headers: @headers, as: :json
    assert_response :success

    payload = JSON.parse(REDIS.lrange(BatchEventProcessorJob::REDIS_KEY, 0, -1).first, symbolize_names: true)
    assert_equal campaigns(:one).id, payload[:campaign_id]
    assert_equal true, payload[:sdk_generated]
    assert_equal @visitor.id, payload[:link_visitor_id]
    assert_match(/\A[a-f0-9]{32}\z/, payload[:event_id])
  ensure
    REDIS.del(BatchEventProcessorJob::REDIS_KEY)
  end

  test "batch builder freezes source for custom events too" do
    @link.update_columns(campaign_id: campaigns(:one).id, visitor_id: @visitor.id, sdk_generated: true)
    @link.send(:clear_cache) # update_columns bypasses cache invalidation; controller resolves via the model cache
    REDIS.del(BatchEventProcessorJob::REDIS_KEY)

    post "#{SDK_PREFIX}/events/batch",
      params: { events: [{ event_name: "add_to_cart", path: @link.path }] },
      headers: @headers, as: :json
    assert_response :success

    payload = JSON.parse(REDIS.lrange(BatchEventProcessorJob::REDIS_KEY, 0, -1).first, symbolize_names: true)
    assert_equal campaigns(:one).id, payload[:campaign_id]
    assert_equal @visitor.id, payload[:link_visitor_id]
    assert_match(/\A[a-f0-9]{32}\z/, payload[:event_id])
  ensure
    REDIS.del(BatchEventProcessorJob::REDIS_KEY)
  end

  # --- Validation ---

  test "non-array events returns 400" do
    post "#{SDK_PREFIX}/events/batch",
      params: { events: "not_an_array" },
      headers: @headers,
      as: :json

    assert_response :bad_request
    json = JSON.parse(response.body)
    assert_equal "events must be an array", json["error"]
  end

  test "empty events array returns 400" do
    post "#{SDK_PREFIX}/events/batch",
      params: { events: [] },
      headers: @headers,
      as: :json

    assert_response :bad_request
    json = JSON.parse(response.body)
    assert_equal "events must not be empty", json["error"]
  end

  test "batch exceeding MAX_BATCH_SIZE returns 400" do
    events = 51.times.map { { event: "app_open" } }

    post "#{SDK_PREFIX}/events/batch",
      params: { events: events },
      headers: @headers,
      as: :json

    assert_response :bad_request
    json = JSON.parse(response.body)
    assert_match(/max 50/, json["error"])
  end

  # --- Auth ---

  test "missing SDK headers returns 403" do
    post "#{SDK_PREFIX}/events/batch",
      params: { events: [{ event: "app_open" }] },
      headers: { "Host" => sdk_host },
      as: :json

    assert_response :forbidden
  end

  test "unknown system event type is rejected" do
    REDIS.stub(:lpush, ->(_, _) {}) do
      post "#{SDK_PREFIX}/events/batch",
        params: {
          events: [
            { event: "banana" },
            { event: "app_open" }
          ]
        },
        headers: @headers,
        as: :json
    end

    assert_response :ok
    json = JSON.parse(response.body)
    assert_equal 1, json["accepted"]
    assert_equal 1, json["rejected"]
    assert_equal 0, json["errors"][0]["index"]
    assert_match(/unknown event type/, json["errors"][0]["error"])
  end

  # --- Happy path ---

  test "batch of mixed events: system + custom + screen_view all accepted" do
    pushed_payloads = nil

    REDIS.stub(:lpush, ->(key, payloads) { pushed_payloads = payloads }) do
      post "#{SDK_PREFIX}/events/batch",
        params: {
          events: [
            { event: "app_open", session_id: "sess-1" },
            { event_name: "purchase", properties: { item: "sku-1" }, session_id: "sess-1" },
            { event_name: "screen_view", session_id: "sess-1" }
          ]
        },
        headers: @headers,
        as: :json
    end

    assert_response :ok
    json = JSON.parse(response.body)
    assert_equal 3, json["accepted"]
    assert_equal 0, json["rejected"]
    assert_empty json["errors"]

    assert_equal 3, pushed_payloads.size
    parsed = pushed_payloads.map { |p| JSON.parse(p) }

    # System event
    assert_equal "app_open", parsed[0]["type"]
    assert_equal @project.id, parsed[0]["project_id"]
    assert_nil parsed[0]["data"]

    # Custom event
    assert_equal Grovs::Events::CUSTOM, parsed[1]["type"]
    assert_equal "purchase", parsed[1]["event_name"]
    assert_equal({ "item" => "sku-1" }, parsed[1]["data"])

    # Screen view
    assert_equal Grovs::Events::SCREEN_VIEW, parsed[2]["type"]
    assert_equal "screen_view", parsed[2]["event_name"]
  end

  test "SDK batch event is processed into ClickHouse and reported by analytics events API" do
    skip_unless_clickhouse!
    pushed_payloads = nil

    REDIS.stub(:lpush, ->(key, payloads) {
      assert_equal BatchEventProcessorJob::REDIS_KEY, key
      pushed_payloads = Array(payloads)
    }) do
      post "#{SDK_PREFIX}/events/batch",
        params: {
          events: [
            {
              event_name: "purchase_completed",
              properties: { plan: "pro", amount: 1299, screen_name: "Checkout" },
              session_id: "sess_e2e_contract",
              tags: ["checkout", "revenue"]
            }
          ]
        },
        headers: @headers,
        as: :json
    end

    assert_response :ok
    response_json = JSON.parse(response.body)
    assert_equal 1, response_json["accepted"]
    assert_equal 0, response_json["rejected"]
    assert_empty response_json["errors"]
    assert_equal 1, pushed_payloads.size

    job = BatchEventProcessorJob.new
    job.jid = "sdk-e2e-#{SecureRandom.hex(4)}"
    assert_difference "Event.count", 1 do
      job.send(:process_batch, pushed_payloads)
    end

    Clickhouse.stub(:read_enabled?, true) do
      get "#{API_PREFIX}/projects/#{@project.id}/analytics/events",
          params: {
            start_date: Date.yesterday.to_s,
            end_date: Date.tomorrow.to_s,
            search: "purchase_completed"
          },
          headers: doorkeeper_headers_for(users(:admin_user))
    end

    assert_response :ok
    json = JSON.parse(response.body)
    event = json.fetch("data").find { |row| row["session_id"] == "sess_e2e_contract" }

    assert event, "expected analytics events API to return the SDK-ingested event"
    assert_equal "purchase_completed", event["event_name"]
    assert_equal "Checkout", event["screen_name"],
      "CUSTOM events carry the screen they occurred on from properties.screen_name"
    assert_equal "sess_e2e_contract", event["session_id"]
    assert_equal Grovs::Events::CUSTOM, event["event_type"]
    assert_equal @project.id, event["project_id"].to_i
  end

  test "max-size SDK batch is processed into ClickHouse and reported by analytics events API" do
    skip_unless_clickhouse!
    batch_size = Api::V1::Sdk::EventsController::MAX_BATCH_SIZE
    session_prefix = "sess_max_batch_#{SecureRandom.hex(4)}"
    pushed_payloads = nil

    events = batch_size.times.map do |index|
      {
        event_name: "max_batch_event",
        properties: { batch_index: index, plan: index.even? ? "pro" : "starter" },
        session_id: "#{session_prefix}_#{index}",
        tags: ["max-batch", "analytics"]
      }
    end

    REDIS.stub(:lpush, ->(key, payloads) {
      assert_equal BatchEventProcessorJob::REDIS_KEY, key
      pushed_payloads = Array(payloads)
    }) do
      post "#{SDK_PREFIX}/events/batch",
        params: { events: events },
        headers: @headers,
        as: :json
    end

    assert_response :ok
    response_json = JSON.parse(response.body)
    assert_equal batch_size, response_json["accepted"]
    assert_equal 0, response_json["rejected"]
    assert_empty response_json["errors"]
    assert_equal batch_size, pushed_payloads.size

    job = BatchEventProcessorJob.new
    job.jid = "sdk-max-batch-#{SecureRandom.hex(4)}"
    assert_difference "Event.count", batch_size do
      job.send(:process_batch, pushed_payloads)
    end

    Clickhouse.stub(:read_enabled?, true) do
      get "#{API_PREFIX}/projects/#{@project.id}/analytics/events",
          params: {
            start_date: Date.yesterday.to_s,
            end_date: Date.tomorrow.to_s,
            search: "max_batch_event",
            limit: batch_size,
            include_count: "true"
          },
          headers: doorkeeper_headers_for(users(:admin_user))
    end

    assert_response :ok
    json = JSON.parse(response.body)
    returned = json.fetch("data").select { |row| row["session_id"].to_s.start_with?(session_prefix) }

    assert_equal batch_size, returned.size
    assert_equal batch_size, json["total_count"]
    assert_equal (0...batch_size).map { |i| "#{session_prefix}_#{i}" }.sort,
      returned.map { |row| row["session_id"] }.sort
    assert returned.all? { |row| row["event_name"] == "max_batch_event" }
    assert returned.all? { |row| row["event_type"] == Grovs::Events::CUSTOM }
    assert returned.all? { |row| row["project_id"].to_i == @project.id }
  end

  # --- Partial accept ---

  test "mix of valid and invalid events returns partial accept" do
    pushed_payloads = nil

    REDIS.stub(:lpush, ->(_, payloads) { pushed_payloads = payloads }) do
      post "#{SDK_PREFIX}/events/batch",
        params: {
          events: [
            { event: "app_open" },
            { not_event: "garbage" },
            { event_name: "my_event" }
          ]
        },
        headers: @headers,
        as: :json
    end

    assert_response :ok
    json = JSON.parse(response.body)
    assert_equal 2, json["accepted"]
    assert_equal 1, json["rejected"]
    assert_equal 1, json["errors"].size
    assert_equal 1, json["errors"][0]["index"]
    assert_equal "missing event or event_name", json["errors"][0]["error"]
    assert_equal 2, pushed_payloads.size
  end

  # --- Reserved event_name ---

  test "reserved event_name in batch is rejected with correct index" do
    pushed_payloads = nil

    REDIS.stub(:lpush, ->(_, payloads) { pushed_payloads = payloads }) do
      post "#{SDK_PREFIX}/events/batch",
        params: {
          events: [
            { event_name: "valid_custom" },
            { event_name: "install" }
          ]
        },
        headers: @headers,
        as: :json
    end

    assert_response :ok
    json = JSON.parse(response.body)
    assert_equal 1, json["accepted"]
    assert_equal 1, json["rejected"]
    assert_equal 1, json["errors"][0]["index"]
    assert_match(/reserved/, json["errors"][0]["error"])
    assert_equal 1, pushed_payloads.size
  end

  # --- Properties ---

  test "oversized properties are dropped, event still accepted" do
    huge_props = { "data" => "x" * (Grovs::Enrichment::MAX_PROPERTIES_BYTES + 1) }
    pushed_payloads = nil

    REDIS.stub(:lpush, ->(_, payloads) { pushed_payloads = payloads }) do
      post "#{SDK_PREFIX}/events/batch",
        params: {
          events: [
            { event_name: "big_event", properties: huge_props }
          ]
        },
        headers: @headers,
        as: :json
    end

    assert_response :ok
    json = JSON.parse(response.body)
    assert_equal 1, json["accepted"]

    parsed = JSON.parse(pushed_payloads.first)
    assert_nil parsed["data"], "oversized properties should be dropped"
  end

  test "system event ignores properties" do
    pushed_payloads = nil

    REDIS.stub(:lpush, ->(_, payloads) { pushed_payloads = payloads }) do
      post "#{SDK_PREFIX}/events/batch",
        params: {
          events: [
            { event: "app_open", properties: { ignored: true } }
          ]
        },
        headers: @headers,
        as: :json
    end

    assert_response :ok
    parsed = JSON.parse(pushed_payloads.first)
    assert_nil parsed["data"], "system events should not include properties"
  end

  # --- Link resolution ---

  test "events with path resolve link correctly" do
    link = links(:basic_link)
    pushed_payloads = nil

    LinksService.stub(:link_for_project_and_path, ->(_, _) { link }) do
      REDIS.stub(:lpush, ->(_, payloads) { pushed_payloads = payloads }) do
        post "#{SDK_PREFIX}/events/batch",
          params: {
            events: [
              { event: "open", path: link.path }
            ]
          },
          headers: @headers,
          as: :json
      end
    end

    assert_response :ok
    parsed = JSON.parse(pushed_payloads.first)
    assert_equal link.id, parsed["link_id"]
  end

  # --- Enrichment fields ---

  test "session_id and tags pass through to Redis payloads" do
    pushed_payloads = nil

    REDIS.stub(:lpush, ->(_, payloads) { pushed_payloads = payloads }) do
      post "#{SDK_PREFIX}/events/batch",
        params: {
          events: [
            {
              event_name: "checkout",
              session_id: "sess-abc-123",
              tags: ["promo", "summer"]
            }
          ]
        },
        headers: @headers,
        as: :json
    end

    assert_response :ok
    parsed = JSON.parse(pushed_payloads.first)
    assert_equal "sess-abc-123", parsed["session_id"]
    assert_equal ["promo", "summer"], parsed["tags"]
  end

  # --- All events rejected ---

  test "all events invalid results in no Redis push" do
    redis_called = false

    REDIS.stub(:lpush, ->(*_args) { redis_called = true }) do
      post "#{SDK_PREFIX}/events/batch",
        params: {
          events: [
            { neither: "event nor event_name" },
            { also: "invalid" }
          ]
        },
        headers: @headers,
        as: :json
    end

    assert_response :ok
    assert_not redis_called, "Redis should not be called when all events are rejected"

    json = JSON.parse(response.body)
    assert_equal 0, json["accepted"]
    assert_equal 2, json["rejected"]
  end

  # --- created_at handling ---

  test "created_at is parsed and included in payload" do
    pushed_payloads = nil
    timestamp = "2026-05-07T12:00:00.000Z"

    REDIS.stub(:lpush, ->(_, payloads) { pushed_payloads = payloads }) do
      post "#{SDK_PREFIX}/events/batch",
        params: {
          events: [
            { event: "app_open", created_at: timestamp }
          ]
        },
        headers: @headers,
        as: :json
    end

    assert_response :ok
    parsed = JSON.parse(pushed_payloads.first)
    assert_equal Time.parse(timestamp).iso8601(3), parsed["created_at"]
  end

  test "a future created_at is clamped to now in the batch payload" do
    pushed_payloads = nil

    REDIS.stub(:lpush, ->(_, payloads) { pushed_payloads = payloads }) do
      post "#{SDK_PREFIX}/events/batch",
        params: { events: [{ event: "app_open", created_at: 2.years.from_now.iso8601(3) }] },
        headers: @headers, as: :json
    end

    assert_response :ok
    parsed = JSON.parse(pushed_payloads.first)
    assert_in_delta Time.current.to_f, Time.parse(parsed["created_at"]).to_f, 5.0
  end

  # The id is hashed from the instant, so clamping must happen before it is frozen.
  test "a clamped created_at agrees with the frozen event_id" do
    pushed_payloads = nil
    future = 2.years.from_now

    REDIS.stub(:lpush, ->(_, payloads) { pushed_payloads = payloads }) do
      post "#{SDK_PREFIX}/events/batch",
        params: { events: [{ event: "app_open", created_at: future.iso8601(3) }] },
        headers: @headers, as: :json
    end

    parsed = JSON.parse(pushed_payloads.first)
    stored = Time.parse(parsed["created_at"])
    expected = EventIngestionService.frozen_ch_fields(
      "app_open", parsed["project_id"], parsed["device_id"], nil, stored, "", "", nil, nil
    )
    assert_equal expected[:event_id], parsed["event_id"]
    assert_not_equal future.iso8601(3), parsed["created_at"]
  end

  test "a custom event's future created_at is clamped too" do
    pushed_payloads = nil

    REDIS.stub(:lpush, ->(_, payloads) { pushed_payloads = payloads }) do
      post "#{SDK_PREFIX}/events/batch",
        params: { events: [{ event_name: "checkout", created_at: 5.days.from_now.iso8601(3) }] },
        headers: @headers, as: :json
    end

    assert_response :ok
    parsed = JSON.parse(pushed_payloads.first)
    assert_in_delta Time.current.to_f, Time.parse(parsed["created_at"]).to_f, 5.0
  end

  test "batch builder folds the sdk event id into the frozen event_id" do
    REDIS.del(BatchEventProcessorJob::REDIS_KEY)

    post "#{SDK_PREFIX}/events/batch",
      params: { events: [
        { event: "app_open", created_at: "2026-08-06T12:00:00.000Z", session_id: "s1", event_id: "uuid-a" },
        { event: "app_open", created_at: "2026-08-06T12:00:00.000Z", session_id: "s1", event_id: "uuid-b" }
      ] },
      headers: @headers, as: :json
    assert_response :success
    assert_equal 2, response.parsed_body["accepted"]

    ids = REDIS.lrange(BatchEventProcessorJob::REDIS_KEY, 0, -1)
               .map { |p| JSON.parse(p, symbolize_names: true)[:event_id] }
    assert_equal 2, ids.uniq.size, "same-ms identical events must not share an id when client ids differ"
    ids.each { |id| assert_match(/\A[a-f0-9]{32}\z/, id) }
  ensure
    REDIS.del(BatchEventProcessorJob::REDIS_KEY)
  end

  test "batch reports a colliding event as rejected instead of accepted" do
    REDIS.del(BatchEventProcessorJob::REDIS_KEY)

    post "#{SDK_PREFIX}/events/batch",
      params: { events: [
        { event: "app_open", created_at: "2026-08-06T12:00:00.000Z", session_id: "s1", event_id: "dup" },
        { event: "app_open", created_at: "2026-08-06T12:00:00.000Z", session_id: "s1", event_id: "dup" }
      ] },
      headers: @headers, as: :json
    assert_response :success

    assert_equal 1, response.parsed_body["accepted"]
    assert_equal 1, response.parsed_body["rejected"]
    assert_equal 1, response.parsed_body["errors"].first["index"]
    assert_match(/duplicate/i, response.parsed_body["errors"].first["error"])
    assert_equal 1, REDIS.llen(BatchEventProcessorJob::REDIS_KEY)
  ensure
    REDIS.del(BatchEventProcessorJob::REDIS_KEY)
  end

  test "identical events without client ids are both accepted, never rejected" do
    REDIS.del(BatchEventProcessorJob::REDIS_KEY)

    post "#{SDK_PREFIX}/events/batch",
      params: { events: [
        { event: "app_open", created_at: "2026-08-06T12:00:00.000Z", session_id: "s1" },
        { event: "app_open", created_at: "2026-08-06T12:00:00.000Z", session_id: "s1" }
      ] },
      headers: @headers, as: :json
    assert_response :success

    assert_equal 2, response.parsed_body["accepted"],
      "content-hash collisions must not be rejected — the JS SDK drops rejected events permanently"
    assert_equal 0, response.parsed_body["rejected"]
    assert_equal 2, REDIS.llen(BatchEventProcessorJob::REDIS_KEY)
  ensure
    REDIS.del(BatchEventProcessorJob::REDIS_KEY)
  end

  test "batch tolerates a non-scalar event_id without erroring" do
    REDIS.del(BatchEventProcessorJob::REDIS_KEY)

    post "#{SDK_PREFIX}/events/batch",
      params: { events: [{ event: "app_open", event_id: { "a" => "b" } }] },
      headers: @headers, as: :json
    assert_response :success
    assert_equal 1, response.parsed_body["accepted"]

    payload = JSON.parse(REDIS.lrange(BatchEventProcessorJob::REDIS_KEY, 0, -1).first, symbolize_names: true)
    assert_match(/\A[a-f0-9]{32}\z/, payload[:event_id])
  ensure
    REDIS.del(BatchEventProcessorJob::REDIS_KEY)
  end

  test "custom batch events carry the sdk event id into identity" do
    REDIS.del(BatchEventProcessorJob::REDIS_KEY)

    post "#{SDK_PREFIX}/events/batch",
      params: { events: [
        { event_name: "tap", created_at: "2026-08-06T12:00:00.000Z", session_id: "s1", event_id: "c-a" },
        { event_name: "tap", created_at: "2026-08-06T12:00:00.000Z", session_id: "s1", event_id: "c-b" }
      ] },
      headers: @headers, as: :json
    assert_response :success

    ids = REDIS.lrange(BatchEventProcessorJob::REDIS_KEY, 0, -1)
               .map { |p| JSON.parse(p, symbolize_names: true)[:event_id] }
    assert_equal 2, ids.uniq.size
  ensure
    REDIS.del(BatchEventProcessorJob::REDIS_KEY)
  end

  test "batch caps migration fallback resolutions per request" do
    enable_migrations!
    REDIS.del(BatchEventProcessorJob::REDIS_KEY)
    ENV["GROVS_SELF_HOSTED"] = "true"
    MigrationSource.delete_all
    MigrationSource.create!(
      project: @project, old_host: "xyz.app.link",
      provider: Grovs::Migrations::PROVIDER_BRANCH,
      credentials: { "branch_key" => "k" }, provider_hosted: true
    )

    calls = 0
    counting = lambda do |url, expected_project:|
      calls += 1
      nil
    end
    MigrationResolver.stub(:resolve_from_sdk, counting) do
      post "#{SDK_PREFIX}/events/batch",
        params: { events: (1..5).map { |i| { event: "install", link: "https://xyz.app.link/slug-#{i}" } } },
        headers: @headers, as: :json
    end
    assert_response :success
    assert_equal 3, calls, "fallback upstream resolution must be capped per request"
  ensure
    REDIS.del(BatchEventProcessorJob::REDIS_KEY)
    disable_migrations!
  end

  test "batch INSTALL with a provider-hosted migration URL resolves link_id via the migration fallback" do
    enable_migrations!
    REDIS.del(BatchEventProcessorJob::REDIS_KEY)
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

    post "#{SDK_PREFIX}/events/batch",
      params: { events: [
        { event: "install", link: "https://xyz-alternate.app.link/abc" },
        { event: "app_open", link: "https://xyz-alternate.app.link/abc" }
      ] },
      headers: @headers, as: :json
    assert_response :success

    payloads = REDIS.lrange(BatchEventProcessorJob::REDIS_KEY, 0, -1)
                    .map { |p| JSON.parse(p, symbolize_names: true) }
    install  = payloads.find { |p| p[:type] == "install" }
    app_open = payloads.find { |p| p[:type] == "app_open" }
    assert_equal @link.id, install[:link_id], "batch install must attribute via MigrationResolver"
    assert_nil app_open[:link_id], "non-install batch events must not use the fallback"
  ensure
    REDIS.del(BatchEventProcessorJob::REDIS_KEY)
    disable_migrations!
  end
end
