require "test_helper"

# Verifies the per-IP throttle BUCKETS apply to the right hosts. The unit test in
# test/initializers/rack_attack_host_test.rb covers the reserved_main_host? predicate;
# this confirms each throttle block actually wires that predicate into the right bucket
# under a real Rack::Attack middleware pass.
#
# Production registers throttles inside `if Rails.env.production?`, so each test
# re-registers ONE bucket with a low limit and verifies it fires (or doesn't) for the
# expected host. Isolating one bucket per test matches how rack-attack rules layer
# independently — sdk.sqd.link traffic also counts against the general bucket in
# production; the SDK bucket fires per-second on top of it.
class RackAttackThrottleIntegrationTest < ActionDispatch::IntegrationTest
  setup do
    @original_enabled = Rack::Attack.enabled
    @original_store = Rack::Attack.cache.store

    Rack::Attack.cache.store = ActiveSupport::Cache::MemoryStore.new
    Rack::Attack.clear_configuration
    # clear_configuration resets the throttled_responder to rack-attack's default (429);
    # mirror production (503) so the response status check matches prod behavior.
    Rack::Attack.throttled_responder = ->(_req) { [503, {}, ["Server Error\n"]] }
    Rack::Attack.enabled = true

    @matched = []
    @subscription = ActiveSupport::Notifications.subscribe("throttle.rack_attack") do |_, _, _, _, payload|
      @matched << payload[:request].env["rack.attack.matched"]
    end
  end

  teardown do
    ActiveSupport::Notifications.unsubscribe(@subscription) if @subscription
    Rack::Attack.cache.store = @original_store
    Rack::Attack.clear_configuration
    Rack::Attack.enabled = @original_enabled
  end

  test "sdk-requests/ip bucket fires for sdk.sqd.link" do
    register_sdk_bucket(limit: 1)

    2.times { get "/x", headers: { "Host" => "sdk.sqd.link" } }

    assert_equal 503, response.status, "second request should be throttled"
    assert_includes @matched, "sdk-requests/ip"
  end

  test "sdk-requests/ip bucket does NOT fire for custom hosts that merely start with sdk." do
    register_sdk_bucket(limit: 1)

    3.times { get "/x", headers: { "Host" => "sdk.acme.com" } }

    assert_not_equal 503, response.status, "custom host must not trip the SDK bucket"
    assert_not_includes @matched, "sdk-requests/ip"
  end

  test "req/ip general bucket fires for sdk.acme.com" do
    register_general_bucket(limit: 1)

    2.times { get "/x", headers: { "Host" => "sdk.acme.com" } }

    assert_equal 503, response.status
    assert_includes @matched, "req/ip"
  end

  test "req/ip general bucket does NOT fire for api.sqd.link (dashboard API bypass)" do
    register_general_bucket(limit: 1)

    3.times { get "/x", headers: { "Host" => "api.sqd.link" } }

    assert_not_equal 503, response.status, "api.sqd.link must bypass the general bucket"
    assert_not_includes @matched, "req/ip"
  end

  test "req/ip general bucket fires for api.acme.com (custom host with reserved label)" do
    # Regression: a customer hostname starting with `api.` must NOT inherit the API bypass.
    register_general_bucket(limit: 1)

    2.times { get "/x", headers: { "Host" => "api.acme.com" } }

    assert_equal 503, response.status
    assert_includes @matched, "req/ip"
  end

  test "audit_export/token bucket fires per export token on the api host" do
    register_audit_export_bucket(limit: 1)
    headers = { "Host" => "api.sqd.link", "Authorization" => "Bearer aet_abc" }

    2.times { get "/api/v1/instances/1/audit_events", headers: headers }

    assert_equal 503, response.status, "second pull with the same export token should be throttled"
    assert_includes @matched, "audit_export/token"
  end

  test "audit_export/token bucket does NOT fire for a Doorkeeper bearer" do
    register_audit_export_bucket(limit: 1)
    headers = { "Host" => "api.sqd.link", "Authorization" => "Bearer notanexporttoken" }

    3.times { get "/api/v1/instances/1/audit_events", headers: headers }

    assert_not_equal 503, response.status, "dashboard sessions must not count against the export bucket"
    assert_not_includes @matched, "audit_export/token"
  end

  private

  def register_audit_export_bucket(limit:)
    Rack::Attack.throttle("audit_export/token", limit: limit, period: 60) do |req|
      if Rack::Attack.reserved_main_host?(req.host, Grovs::Subdomains::API) && req.path.match?(%r{/api/v1/instances/\w+/audit_events})
        auth = req.env["HTTP_AUTHORIZATION"].to_s
        Digest::SHA256.hexdigest(auth) if auth.include?("aet_")
      end
    end
  end

  # 60s window, not prod's 1s — a second boundary between requests resets the counter.
  def register_sdk_bucket(limit:)
    Rack::Attack.throttle("sdk-requests/ip", limit: limit, period: 60) do |req|
      if Rack::Attack.reserved_main_host?(req.host, Grovs::Subdomains::SDK)
        req.ip
      end
    end
  end

  def register_general_bucket(limit:)
    Rack::Attack.throttle("req/ip", limit: limit, period: 60) do |req|
      unless Rack::Attack.reserved_main_host?(req.host, Grovs::Subdomains::API) || req.host&.start_with?("dls")
        req.ip
      end
    end
  end
end
