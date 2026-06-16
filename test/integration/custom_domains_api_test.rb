require "test_helper"
require_relative "auth_test_helper"

class CustomDomainsApiTest < ActionDispatch::IntegrationTest
  include AuthTestHelper

  fixtures :instances, :users, :instance_roles, :projects, :domains, :redirect_configs, :stripe_payment_intents, :stripe_subscriptions

  setup do
    enable_custom_domains!
    REDIS.flushdb
    CustomHostname.delete_all # fixtures are a shared baseline across the run; start clean
  end
  teardown { disable_custom_domains! }

  test "create requires an entitled instance (402)" do
    post "#{API_PREFIX}/projects/#{projects(:two).id}/custom_domain",
         params: { hostname: "links.newco.com" }, headers: doorkeeper_headers_for(users(:super_admin_user))
    assert_response :payment_required
  end

  test "create provisions and returns the CNAME target" do
    CloudflareCustomHostnameService.stub(:create, { success: true, cf_id: "cf_new", status: "pending", ssl_status: "pending_validation" }) do
      post "#{API_PREFIX}/projects/#{projects(:one).id}/custom_domain",
           params: { hostname: "links.acmeco.com" }, headers: doorkeeper_headers_for(users(:admin_user))
    end
    assert_response :created
    json = JSON.parse(response.body)
    assert_equal "links.acmeco.com", json.dig("custom_domain", "hostname")
    assert_equal "proxy.sqd.link", json.dig("custom_domain", "cname_target")
    assert CustomHostname.exists?(hostname: "links.acmeco.com", status: "pending")
  end

  test "create rejects an unavailable (apex) hostname (422)" do
    post "#{API_PREFIX}/projects/#{projects(:one).id}/custom_domain",
         params: { hostname: "acmeco.com" }, headers: doorkeeper_headers_for(users(:admin_user))
    assert_response :unprocessable_entity
  end

  test "GET returns null when none, the row when present" do
    headers = doorkeeper_headers_for(users(:admin_user))
    get "#{API_PREFIX}/projects/#{projects(:one).id}/custom_domain", headers: headers
    assert_response :ok
    assert_nil JSON.parse(response.body)["custom_domain"]

    CustomHostname.create!(project: projects(:one), domain: domains(:one), hostname: "links.acmeco.com", status: "active", source: "saas")
    get "#{API_PREFIX}/projects/#{projects(:one).id}/custom_domain", headers: doorkeeper_headers_for(users(:admin_user))
    assert_equal "links.acmeco.com", JSON.parse(response.body).dig("custom_domain", "hostname")
  end

  test "delete removes the row" do
    ch = CustomHostname.create!(project: projects(:one), domain: domains(:one), hostname: "links.del.com", cf_custom_hostname_id: "cf_d", status: "active", 
source: "saas")
    CloudflareCustomHostnameService.stub(:delete, true) do
      delete "#{API_PREFIX}/projects/#{projects(:one).id}/custom_domain", headers: doorkeeper_headers_for(users(:admin_user))
    end
    assert_response :ok
    assert_not CustomHostname.exists?(ch.id)
  end

  test "returns 404 when the feature is disabled" do
    disable_custom_domains!
    post "#{API_PREFIX}/projects/#{projects(:one).id}/custom_domain",
         params: { hostname: "links.acmeco.com" }, headers: doorkeeper_headers_for(users(:admin_user))
    assert_response :not_found
  end

  test "requires authentication" do
    post "#{API_PREFIX}/projects/#{projects(:one).id}/custom_domain",
         params: { hostname: "links.acmeco.com" }, headers: api_headers
    assert_response :unauthorized
  end

  # ---------------------------------------------------------------------------
  # Per-project rate limit on create/delete (CF quota + enumeration-oracle guard).
  # ---------------------------------------------------------------------------

  test "create/delete are throttled to 10/min per project with a 429 + Retry-After" do
    limit = Api::V1::DomainsController::CUSTOM_DOMAIN_OPS_RATE_LIMIT_PER_MINUTE
    headers = doorkeeper_headers_for(users(:admin_user))

    # Pre-saturate the per-project bucket so the very next call trips the throttle.
    bucket = Time.current.to_i / 60
    key = "custom_domain_ops:rate:#{projects(:one).id}:#{bucket}"
    REDIS.with { |c| c.set(key, limit, ex: 65) }

    # CF call stubbed to flunk: if the throttle let the request through, we'd see this.
    CloudflareCustomHostnameService.stub(:create, ->(*) { flunk "throttled request must not reach Cloudflare" }) do
      post "#{API_PREFIX}/projects/#{projects(:one).id}/custom_domain",
           params: { hostname: "links.acmeco.com" }, headers: headers
    end
    assert_response :too_many_requests
    assert_equal "60", response.headers["Retry-After"]
  end

  test "throttle bucket key is namespaced by project_id (cross-project isolation)" do
    # Structural test: after one request from project one, the bucket key carries
    # project one's id. Confirms saturating one project's bucket cannot starve another.
    bucket = Time.current.to_i / 60
    CloudflareCustomHostnameService.stub(:create, { success: true, cf_id: "cf_iso", status: "pending", ssl_status: "pending_validation" }) do
      post "#{API_PREFIX}/projects/#{projects(:one).id}/custom_domain",
           params: { hostname: "links.iso.com" }, headers: doorkeeper_headers_for(users(:admin_user))
    end
    own = REDIS.with { |c| c.get("custom_domain_ops:rate:#{projects(:one).id}:#{bucket}") }
    other = REDIS.with { |c| c.get("custom_domain_ops:rate:#{projects(:two).id}:#{bucket}") }
    assert_equal "1", own
    assert_nil other, "project two's bucket must NOT be touched by project one's request"
  end

  test "delete is counted against the same per-project bucket as create" do
    limit = Api::V1::DomainsController::CUSTOM_DOMAIN_OPS_RATE_LIMIT_PER_MINUTE
    CustomHostname.create!(project: projects(:one), domain: domains(:one), hostname: "links.del2.com",
                           cf_custom_hostname_id: "cf_d2", status: "active", source: "saas")
    bucket = Time.current.to_i / 60
    REDIS.with { |c| c.set("custom_domain_ops:rate:#{projects(:one).id}:#{bucket}", limit, ex: 65) }

    CloudflareCustomHostnameService.stub(:delete, ->(*) { flunk "throttled delete must not reach Cloudflare" }) do
      delete "#{API_PREFIX}/projects/#{projects(:one).id}/custom_domain",
             headers: doorkeeper_headers_for(users(:admin_user))
    end
    assert_response :too_many_requests
  end

  test "read endpoints (GET custom_domain) are NOT throttled" do
    limit = Api::V1::DomainsController::CUSTOM_DOMAIN_OPS_RATE_LIMIT_PER_MINUTE
    bucket = Time.current.to_i / 60
    REDIS.with { |c| c.set("custom_domain_ops:rate:#{projects(:one).id}:#{bucket}", limit, ex: 65) }

    get "#{API_PREFIX}/projects/#{projects(:one).id}/custom_domain",
        headers: doorkeeper_headers_for(users(:admin_user))
    assert_response :ok
  end

  test "throttle fails open when Redis is unavailable (admin not locked out of cleanup)" do
    REDIS.stub(:with, ->(*) { raise Redis::CannotConnectError, "down" }) do
      CloudflareCustomHostnameService.stub(:create, { success: true, cf_id: "cf_fo", status: "pending", ssl_status: "pending_validation" }) do
        post "#{API_PREFIX}/projects/#{projects(:one).id}/custom_domain",
             params: { hostname: "links.failopen.com" }, headers: doorkeeper_headers_for(users(:admin_user))
      end
    end
    assert_response :created, "Redis outage must NOT lock admins out of custom-domain management"
  end
end
