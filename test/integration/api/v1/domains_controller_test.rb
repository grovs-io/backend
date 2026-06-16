require "test_helper"
require_relative "../../auth_test_helper"

class Api::V1::DomainsControllerTest < ActionDispatch::IntegrationTest
  include AuthTestHelper

  fixtures :instances, :users, :instance_roles, :projects, :domains, :redirect_configs,
           :stripe_payment_intents, :stripe_subscriptions

  setup do
    enable_custom_domains!
    REDIS.flushdb
    CustomHostname.delete_all
  end

  teardown { disable_custom_domains! }

  test "legacy GET /custom_domain returns only the primary purpose row" do
    seed_primary_and_migration!

    get "#{API_PREFIX}/projects/#{projects(:one).id}/custom_domain",
        headers: doorkeeper_headers_for(users(:admin_user))
    assert_response :ok

    payload = JSON.parse(response.body)["custom_domain"]
    assert_equal "links.acmeco.com", payload["hostname"]
    assert_equal "primary", payload["purpose"]
  end

  test "legacy DELETE /custom_domain deletes the primary and leaves the migration row" do
    seed_primary_and_migration!

    CloudflareCustomHostnameService.stub(:delete, true) do
      delete "#{API_PREFIX}/projects/#{projects(:one).id}/custom_domain",
             headers: doorkeeper_headers_for(users(:admin_user))
    end
    assert_response :ok

    assert_nil CustomHostname.find_by(project: projects(:one), purpose: "primary")
    migration = CustomHostname.find_by(project: projects(:one), purpose: "migration")
    assert_not_nil migration
    assert_equal "old-branch.acmeco.com", migration.hostname
  end

  test "plural GET /custom_domains returns both purposes with primary first" do
    # Insertion order is migration then primary to prove ordering comes from SQL CASE.
    CustomHostname.create!(project: projects(:one), domain: domains(:one),
                           hostname: "old-branch.acmeco.com", status: "active",
                           source: "saas", purpose: "migration")
    CustomHostname.create!(project: projects(:one), domain: domains(:one),
                           hostname: "links.acmeco.com", status: "active",
                           source: "saas", purpose: "primary")

    get "#{API_PREFIX}/projects/#{projects(:one).id}/custom_domains",
        headers: doorkeeper_headers_for(users(:admin_user))
    assert_response :ok

    body = JSON.parse(response.body)
    assert_kind_of Array, body["custom_domains"]
    assert_equal 2, body["custom_domains"].length
    assert_equal "primary",   body["custom_domains"][0]["purpose"]
    assert_equal "migration", body["custom_domains"][1]["purpose"]
    assert_equal "links.acmeco.com",       body["custom_domains"][0]["hostname"]
    assert_equal "old-branch.acmeco.com",  body["custom_domains"][1]["hostname"]
  end

  test "plural GET /custom_domains returns an empty array when no hostnames" do
    get "#{API_PREFIX}/projects/#{projects(:one).id}/custom_domains",
        headers: doorkeeper_headers_for(users(:admin_user))
    assert_response :ok
    assert_equal [], JSON.parse(response.body)["custom_domains"]
  end

  test "plural GET /custom_domains is 404 when the feature is disabled" do
    disable_custom_domains!
    get "#{API_PREFIX}/projects/#{projects(:one).id}/custom_domains",
        headers: doorkeeper_headers_for(users(:admin_user))
    assert_response :not_found
  end

  test "plural POST /custom_domains creates a migration purpose row" do
    CloudflareCustomHostnameService.stub(:create, { success: true, cf_id: "cf_mig", status: "pending", ssl_status: "pending_validation" }) do
      post "#{API_PREFIX}/projects/#{projects(:one).id}/custom_domains",
           params: { hostname: "old-branch.acmeco.com", purpose: "migration" },
           headers: doorkeeper_headers_for(users(:admin_user))
    end
    assert_response :created

    payload = JSON.parse(response.body)["custom_domain"]
    assert_equal "old-branch.acmeco.com", payload["hostname"]
    assert_equal "migration", payload["purpose"]

    row = CustomHostname.find_by!(hostname: "old-branch.acmeco.com")
    assert_equal "migration", row.purpose
    assert_equal projects(:one).id, row.project_id
  end

  test "plural POST /custom_domains without purpose returns 422" do
    without_contract_check do
      post "#{API_PREFIX}/projects/#{projects(:one).id}/custom_domains",
           params: { hostname: "old-branch.acmeco.com" },
           headers: doorkeeper_headers_for(users(:admin_user))
    end
    assert_response :unprocessable_entity
    body = JSON.parse(response.body)
    assert_equal "Invalid purpose", body["error"]
    assert_not CustomHostname.exists?(hostname: "old-branch.acmeco.com")
  end

  test "plural POST /custom_domains with unknown purpose returns 422" do
    without_contract_check do
      post "#{API_PREFIX}/projects/#{projects(:one).id}/custom_domains",
           params: { hostname: "old-branch.acmeco.com", purpose: "garbage" },
           headers: doorkeeper_headers_for(users(:admin_user))
    end
    assert_response :unprocessable_entity
    body = JSON.parse(response.body)
    assert_equal "Invalid purpose", body["error"]
    assert_not CustomHostname.exists?(hostname: "old-branch.acmeco.com")
  end

  test "plural DELETE /custom_domains without ?purpose returns 422" do
    seed_primary_and_migration!

    without_contract_check do
      delete "#{API_PREFIX}/projects/#{projects(:one).id}/custom_domains",
             headers: doorkeeper_headers_for(users(:admin_user))
    end
    assert_response :unprocessable_entity
    assert_equal 2, projects(:one).custom_hostnames.count
  end

  test "plural DELETE /custom_domains?purpose=migration deletes migration only" do
    seed_primary_and_migration!

    CloudflareCustomHostnameService.stub(:delete, true) do
      delete "#{API_PREFIX}/projects/#{projects(:one).id}/custom_domains?purpose=migration",
             headers: doorkeeper_headers_for(users(:admin_user))
    end
    assert_response :ok

    assert_not CustomHostname.exists?(project: projects(:one), purpose: "migration")
    primary = CustomHostname.find_by(project: projects(:one), purpose: "primary")
    assert_not_nil primary
    assert_equal "links.acmeco.com", primary.hostname
  end

  test "plural DELETE /custom_domains?purpose=migration 404 when none configured" do
    CustomHostname.create!(project: projects(:one), domain: domains(:one),
                           hostname: "links.acmeco.com", status: "active",
                           source: "saas", purpose: "primary")
    delete "#{API_PREFIX}/projects/#{projects(:one).id}/custom_domains?purpose=migration",
           headers: doorkeeper_headers_for(users(:admin_user))
    assert_response :not_found
    assert CustomHostname.exists?(project: projects(:one), purpose: "primary")
  end

  test "plural POST /custom_domains is counted against the same per-project rate-limit bucket" do
    limit = Api::V1::DomainsController::CUSTOM_DOMAIN_OPS_RATE_LIMIT_PER_MINUTE
    bucket = Time.current.to_i / 60
    REDIS.with { |c| c.set("custom_domain_ops:rate:#{projects(:one).id}:#{bucket}", limit, ex: 65) }

    CloudflareCustomHostnameService.stub(:create, ->(*) { flunk "throttled request must not reach Cloudflare" }) do
      post "#{API_PREFIX}/projects/#{projects(:one).id}/custom_domains",
           params: { hostname: "old-branch.acmeco.com", purpose: "migration" },
           headers: doorkeeper_headers_for(users(:admin_user))
    end
    assert_response :too_many_requests
    assert_equal "60", response.headers["Retry-After"]
  end

  test "plural GET /custom_domains (read-only) is NOT throttled" do
    limit = Api::V1::DomainsController::CUSTOM_DOMAIN_OPS_RATE_LIMIT_PER_MINUTE
    bucket = Time.current.to_i / 60
    REDIS.with { |c| c.set("custom_domain_ops:rate:#{projects(:one).id}:#{bucket}", limit, ex: 65) }

    get "#{API_PREFIX}/projects/#{projects(:one).id}/custom_domains",
        headers: doorkeeper_headers_for(users(:admin_user))
    assert_response :ok
  end

  # Reaching :ok proves the request + response schemas accept ?purpose= — otherwise
  # ApiContracts::ContractError would raise before the assertion.
  test "plural DELETE /custom_domains?purpose=migration round-trips through the contract validator" do
    seed_primary_and_migration!

    CloudflareCustomHostnameService.stub(:delete, true) do
      delete "#{API_PREFIX}/projects/#{projects(:one).id}/custom_domains?purpose=migration",
             headers: doorkeeper_headers_for(users(:admin_user))
    end
    assert_response :ok
    assert_equal "Custom domain removed", JSON.parse(response.body)["message"]
  end

  private

  def without_contract_check
    previous = ENV["SKIP_API_CONTRACTS"]
    ENV["SKIP_API_CONTRACTS"] = "true"
    yield
  ensure
    ENV["SKIP_API_CONTRACTS"] = previous
  end

  def seed_primary_and_migration!
    CustomHostname.create!(project: projects(:one), domain: domains(:one),
                           hostname: "links.acmeco.com", cf_custom_hostname_id: "cf_p",
                           status: "active", source: "saas", purpose: "primary")
    CustomHostname.create!(project: projects(:one), domain: domains(:one),
                           hostname: "old-branch.acmeco.com", cf_custom_hostname_id: "cf_m",
                           status: "active", source: "saas", purpose: "migration")
  end
end
