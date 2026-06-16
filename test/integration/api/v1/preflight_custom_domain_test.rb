require "test_helper"
require_relative "../../auth_test_helper"

class Api::V1::PreflightCustomDomainTest < ActionDispatch::IntegrationTest
  include AuthTestHelper

  fixtures :instances, :users, :instance_roles, :projects, :domains,
           :stripe_payment_intents, :stripe_subscriptions

  setup do
    enable_custom_domains!
    # Test env defaults to :null_store; swap in MemoryStore so cache assertions work.
    REDIS.flushdb
    @previous_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
  end

  teardown do
    Rails.cache = @previous_cache
    disable_custom_domains!
  end

  def preflight_url(project, hostname: nil)
    base = "#{API_PREFIX}/projects/#{project.id}/custom_domains/preflight"
    hostname.nil? ? base : "#{base}?hostname=#{hostname}"
  end

  test "returns cname_matches=true when actual equals expected" do
    DnsCnameLookupService.stub(:lookup, ["proxy.sqd.link", nil]) do
      get preflight_url(projects(:one), hostname: "branch.acme.com"),
          headers: doorkeeper_headers_for(users(:admin_user))
    end
    assert_response :ok
    body = JSON.parse(response.body)
    assert_equal "branch.acme.com",  body["hostname"]
    assert_equal "proxy.sqd.link",   body["cname_expected"]
    assert_equal "proxy.sqd.link",   body["cname_actual"]
    assert_equal true,               body["cname_matches"]
    assert body["checked_at"].present?
    assert_nil body["dns_error"]
  end

  test "returns cname_matches=false when CNAME points elsewhere" do
    DnsCnameLookupService.stub(:lookup, ["some.other.host", nil]) do
      get preflight_url(projects(:one), hostname: "branch.acme.com"),
          headers: doorkeeper_headers_for(users(:admin_user))
    end
    assert_response :ok
    body = JSON.parse(response.body)
    assert_equal "some.other.host", body["cname_actual"]
    assert_equal false,             body["cname_matches"]
  end

  test "returns cname_actual=null and cname_matches=false when no CNAME exists" do
    DnsCnameLookupService.stub(:lookup, [nil, nil]) do
      get preflight_url(projects(:one), hostname: "branch.acme.com"),
          headers: doorkeeper_headers_for(users(:admin_user))
    end
    assert_response :ok
    body = JSON.parse(response.body)
    assert_nil body["cname_actual"]
    assert_equal false, body["cname_matches"]
    assert_nil body["dns_error"]
  end

  test "surfaces dns_error and returns 200 on DNS timeout" do
    DnsCnameLookupService.stub(:lookup, [nil, "Resolv::ResolvTimeout"]) do
      get preflight_url(projects(:one), hostname: "branch.acme.com"),
          headers: doorkeeper_headers_for(users(:admin_user))
    end
    assert_response :ok
    body = JSON.parse(response.body)
    assert_nil body["cname_actual"]
    assert_equal false, body["cname_matches"]
    assert_equal "Resolv::ResolvTimeout", body["dns_error"]
  end

  test "treats trailing-dot CNAME as equivalent to dot-less expected" do
    DnsCnameLookupService.stub(:lookup, ["proxy.sqd.link.", nil]) do
      get preflight_url(projects(:one), hostname: "branch.acme.com"),
          headers: doorkeeper_headers_for(users(:admin_user))
    end
    assert_response :ok
    assert_equal true, JSON.parse(response.body)["cname_matches"]
  end

  test "matches case-insensitively" do
    DnsCnameLookupService.stub(:lookup, ["PROXY.SQD.LINK", nil]) do
      get preflight_url(projects(:one), hostname: "branch.acme.com"),
          headers: doorkeeper_headers_for(users(:admin_user))
    end
    assert_response :ok
    assert_equal true, JSON.parse(response.body)["cname_matches"]
  end

  test "returns 422 when hostname is missing" do
    without_contract_check do
      get preflight_url(projects(:one)),
          headers: doorkeeper_headers_for(users(:admin_user))
    end
    assert_response :unprocessable_entity
    assert_equal "Hostname is required", JSON.parse(response.body)["error"]
  end

  test "returns 422 when hostname is blank" do
    without_contract_check do
      get preflight_url(projects(:one), hostname: "%20"),
          headers: doorkeeper_headers_for(users(:admin_user))
    end
    assert_response :unprocessable_entity
    assert_equal "Hostname is required", JSON.parse(response.body)["error"]
  end

  test "returns 422 on non-ASCII hostname" do
    get preflight_url(projects(:one), hostname: "foo.b%C3%A4r.com"),
        headers: doorkeeper_headers_for(users(:admin_user))
    assert_response :unprocessable_entity
    assert_equal "Hostname must be valid ASCII", JSON.parse(response.body)["error"]
  end

  test "strips :port suffix from the hostname param before lookup" do
    captured_host = nil
    stub = lambda do |host|
      captured_host = host
      ["proxy.sqd.link", nil]
    end
    DnsCnameLookupService.stub(:lookup, stub) do
      get preflight_url(projects(:one), hostname: "links.acme.com:443"),
          headers: doorkeeper_headers_for(users(:admin_user))
    end
    assert_response :ok
    assert_equal "links.acme.com", captured_host,
                 "port suffix must be stripped before DNS resolution"
    body = JSON.parse(response.body)
    assert_equal "links.acme.com", body["hostname"],
                 "response hostname must reflect the normalized value"
  end

  test "rejects single-label / dotless hostnames with 422" do
    DnsCnameLookupService.stub(:lookup, ->(*_) { flunk "must not resolve DNS for a structurally invalid host" }) do
      get preflight_url(projects(:one), hostname: "x"),
          headers: doorkeeper_headers_for(users(:admin_user))
    end
    assert_response :unprocessable_entity
    assert_match(/look like a domain/, JSON.parse(response.body)["error"])
  end

  test "accepts a minimal a.b hostname (sanity check that the dot-gate doesn't reject legitimate input)" do
    DnsCnameLookupService.stub(:lookup, ["proxy.sqd.link", nil]) do
      get preflight_url(projects(:one), hostname: "a.b"),
          headers: doorkeeper_headers_for(users(:admin_user))
    end
    assert_response :ok
  end

  test "returns 404 when the feature flag is off" do
    disable_custom_domains!
    get preflight_url(projects(:one), hostname: "branch.acme.com"),
        headers: doorkeeper_headers_for(users(:admin_user))
    assert_response :not_found
  end

  test "returns 401 without a Doorkeeper token" do
    get preflight_url(projects(:one), hostname: "branch.acme.com"),
        headers: { "Host" => api_host }
    assert_response :unauthorized
  end

  test "throttle: the 61st preflight call in a minute returns 429 with Retry-After" do
    project = projects(:one)
    limit   = Api::V1::Concerns::CustomDomainOpsThrottling::CUSTOM_DOMAIN_READS_RATE_LIMIT_PER_MINUTE
    bucket  = Time.current.to_i / 60
    REDIS.with { |c| c.set("custom_domain_reads:rate:#{project.id}:#{bucket}", limit, ex: 65) }

    DnsCnameLookupService.stub(:lookup, ->(*_) { flunk "throttled request must not resolve DNS" }) do
      get preflight_url(project, hostname: "branch.acme.com"),
          headers: doorkeeper_headers_for(users(:admin_user))
    end
    assert_response :too_many_requests
    assert_equal "60", response.headers["Retry-After"]
    assert_equal "Too many custom-domain checks for this project — try again in a minute",
                 JSON.parse(response.body)["error"]
  end

  test "cache: second call within TTL hits cache and skips DNS lookup" do
    calls = 0
    lookup_stub = lambda do |_host|
      calls += 1
      ["proxy.sqd.link", nil]
    end

    DnsCnameLookupService.stub(:lookup, lookup_stub) do
      get preflight_url(projects(:one), hostname: "branch.acme.com"),
          headers: doorkeeper_headers_for(users(:admin_user))
      first_checked_at = JSON.parse(response.body)["checked_at"]

      get preflight_url(projects(:one), hostname: "branch.acme.com"),
          headers: doorkeeper_headers_for(users(:admin_user))
      second_checked_at = JSON.parse(response.body)["checked_at"]

      assert_equal 1, calls, "DNS lookup must be called only once across two preflights"
      assert_equal first_checked_at, second_checked_at,
                   "checked_at must reflect the original (cached) lookup time"
    end
  end

  test "cache: explicit cache clear forces a fresh DNS lookup" do
    calls = 0
    lookup_stub = lambda do |_host|
      calls += 1
      ["proxy.sqd.link", nil]
    end

    DnsCnameLookupService.stub(:lookup, lookup_stub) do
      get preflight_url(projects(:one), hostname: "branch.acme.com"),
          headers: doorkeeper_headers_for(users(:admin_user))
      Rails.cache.clear
      get preflight_url(projects(:one), hostname: "branch.acme.com"),
          headers: doorkeeper_headers_for(users(:admin_user))

      assert_equal 2, calls, "post-cache-clear preflight must re-resolve"
    end
  end

  test "throttle: a saturated WRITE-ops bucket does NOT block preflight" do
    bucket = Time.current.to_i / 60
    write_limit = Api::V1::Concerns::CustomDomainOpsThrottling::CUSTOM_DOMAIN_OPS_RATE_LIMIT_PER_MINUTE
    REDIS.with { |c| c.set("custom_domain_ops:rate:#{projects(:one).id}:#{bucket}", write_limit, ex: 65) }

    DnsCnameLookupService.stub(:lookup, ["proxy.sqd.link", nil]) do
      get preflight_url(projects(:one), hostname: "branch.acme.com"),
          headers: doorkeeper_headers_for(users(:admin_user))
    end
    assert_response :ok
    assert_nil response.headers["Retry-After"]
  end

  test "throttle: a saturated READ bucket does NOT block create/delete" do
    bucket = Time.current.to_i / 60
    read_limit = Api::V1::Concerns::CustomDomainOpsThrottling::CUSTOM_DOMAIN_READS_RATE_LIMIT_PER_MINUTE
    REDIS.with { |c| c.set("custom_domain_reads:rate:#{projects(:one).id}:#{bucket}", read_limit, ex: 65) }

    CloudflareCustomHostnameService.stub(:create, { success: true, cf_id: "cf_x", status: "pending", ssl_status: "pending_validation" }) do
      post "#{API_PREFIX}/projects/#{projects(:one).id}/custom_domain",
           params: { hostname: "links.acmeco.com" },
           headers: doorkeeper_headers_for(users(:admin_user))
    end
    assert_response :created
  end

  test "throttle: per-project — saturating project A does NOT block project B" do
    bucket = Time.current.to_i / 60
    read_limit = Api::V1::Concerns::CustomDomainOpsThrottling::CUSTOM_DOMAIN_READS_RATE_LIMIT_PER_MINUTE
    REDIS.with { |c| c.set("custom_domain_reads:rate:#{projects(:one).id}:#{bucket}", read_limit, ex: 65) }

    DnsCnameLookupService.stub(:lookup, ["proxy.sqd.link", nil]) do
      get preflight_url(projects(:two), hostname: "branch.other.com"),
          headers: doorkeeper_headers_for(users(:super_admin_user))
    end
    assert_response :ok
  end

  test "throttle: malformed-hostname requests still consume the bucket (no probe-without-cost)" do
    bucket = Time.current.to_i / 60
    key    = "custom_domain_reads:rate:#{projects(:one).id}:#{bucket}"

    without_contract_check do
      get preflight_url(projects(:one)),
          headers: doorkeeper_headers_for(users(:admin_user))
    end
    assert_response :unprocessable_entity

    counter = REDIS.with { |c| c.get(key) }.to_i
    assert_equal 1, counter,
                 "preflight throttle must charge even malformed requests, else attackers " \
                 "can probe without cost"
  end

  test "cache: per-(project, hostname) — project A's hit is NOT served to project B" do
    actual_calls = []
    lookup_stub = lambda do |host|
      actual_calls << host
      ["proxy.sqd.link", nil]
    end

    DnsCnameLookupService.stub(:lookup, lookup_stub) do
      get preflight_url(projects(:one), hostname: "shared.acme.com"),
          headers: doorkeeper_headers_for(users(:admin_user))
      get preflight_url(projects(:two), hostname: "shared.acme.com"),
          headers: doorkeeper_headers_for(users(:super_admin_user))
    end
    assert_equal 2, actual_calls.size,
                 "two projects must each get their own DNS lookup — cache key " \
                 "must include project_id to prevent cross-tenant leakage"
  end

  test "cache: transient DNS failures are cached too (avoids re-resolving 60×/min)" do
    # If this ever changes ("don't cache errors"), the throttle becomes the only
    # backstop against resolver hammering.
    calls = 0
    lookup_stub = lambda do |_host|
      calls += 1
      [nil, "Resolv::ResolvError"]
    end

    DnsCnameLookupService.stub(:lookup, lookup_stub) do
      2.times do
        get preflight_url(projects(:one), hostname: "broken.acme.com"),
            headers: doorkeeper_headers_for(users(:admin_user))
        assert_response :ok
        assert_equal "Resolv::ResolvError", JSON.parse(response.body)["dns_error"]
      end
    end
    assert_equal 1, calls, "DNS error responses must be cached (TTL applies even to failures)"
  end

  test "auth: non-admin member can call preflight (read-only auth semantics)" do
    DnsCnameLookupService.stub(:lookup, ["proxy.sqd.link", nil]) do
      get preflight_url(projects(:one), hostname: "branch.acme.com"),
          headers: doorkeeper_headers_for(users(:member_user))
    end
    assert_response :ok
  end

  test "auth: caller with NO role on the project's instance is rejected (cross-tenant guard)" do
    DnsCnameLookupService.stub(:lookup, ->(*_) { flunk "must not resolve DNS for an unauthorized project" }) do
      get preflight_url(projects(:two), hostname: "branch.acme.com"),
          headers: doorkeeper_headers_for(users(:admin_user))
    end
    assert_response :forbidden
  end

  test "cache: different hostnames do not share a cache entry" do
    calls = 0
    lookup_stub = lambda do |_host|
      calls += 1
      ["proxy.sqd.link", nil]
    end

    DnsCnameLookupService.stub(:lookup, lookup_stub) do
      get preflight_url(projects(:one), hostname: "one.acme.com"),
          headers: doorkeeper_headers_for(users(:admin_user))
      get preflight_url(projects(:one), hostname: "two.acme.com"),
          headers: doorkeeper_headers_for(users(:admin_user))

      assert_equal 2, calls, "each distinct hostname must trigger its own DNS lookup"
    end
  end

  private

  def without_contract_check
    previous = ENV["SKIP_API_CONTRACTS"]
    ENV["SKIP_API_CONTRACTS"] = "true"
    yield
  ensure
    ENV["SKIP_API_CONTRACTS"] = previous
  end
end
