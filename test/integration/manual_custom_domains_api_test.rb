require "test_helper"
require_relative "auth_test_helper"

class ManualCustomDomainsApiTest < ActionDispatch::IntegrationTest
  include AuthTestHelper

  fixtures :instances, :users, :instance_roles, :projects, :domains, :redirect_configs,
           :stripe_payment_intents, :stripe_subscriptions

  setup do
    enable_manual_custom_domains!
    @saved_server_host = ENV["SERVER_HOST"]
    ENV["SERVER_HOST"] = "links.app.com"
    REDIS.flushdb
    CustomHostname.delete_all
  end
  teardown do
    disable_custom_domains!
    @saved_server_host.nil? ? ENV.delete("SERVER_HOST") : ENV["SERVER_HOST"] = @saved_server_host
  end

  def admin_headers
    doorkeeper_headers_for(users(:admin_user))
  end

  def manual_row(status: "pending", purpose: "primary", hostname: "links.selfhosted.com")
    CustomHostname.create!(project: projects(:one), domain: domains(:one), hostname: hostname,
                           cf_custom_hostname_id: nil, status: status,
                           source: "enterprise", purpose: purpose)
  end

  test "create needs no subscription and returns setup records" do
    post "#{API_PREFIX}/projects/#{projects(:one).id}/custom_domain",
         params: { hostname: "links.selfhosted.com" }, headers: admin_headers

    assert_response :created
    json = JSON.parse(response.body)
    assert_equal "manual", json["tls_mode"]
    assert_equal "links.app.com", json["ingress_host"]
    assert_equal "links.app.com", json.dig("custom_domain", "cname_target")
    assert_equal %w[certificate dns], json.dig("custom_domain", "setup_records").map { |r| r["kind"] }
  end

  test "the index carries the deployment fields even with no domains configured" do
    get "#{API_PREFIX}/projects/#{projects(:one).id}/custom_domains", headers: admin_headers

    assert_response :ok
    json = JSON.parse(response.body)
    assert_empty json["custom_domains"]
    assert_equal "manual", json["tls_mode"]
    assert_equal "links.app.com", json["ingress_host"]
  end

  test "a Cloudflare deployment reports its mode as cloudflare" do
    enable_custom_domains!
    get "#{API_PREFIX}/projects/#{projects(:one).id}/custom_domains", headers: admin_headers

    assert_equal "cloudflare", JSON.parse(response.body)["tls_mode"]
    assert_nil JSON.parse(response.body)["ingress_host"]
  end

  test "verify activates the row when the probe succeeds" do
    ch = manual_row
    SelfHostedDomainVerificationService.stub(:verify, ->(*) { SelfHostedDomainVerificationService::Result.new(active: true) }) do
      post "#{API_PREFIX}/projects/#{projects(:one).id}/custom_domains/verify",
           params: { hostname: ch.hostname }, headers: admin_headers
    end

    assert_response :ok
    assert_equal "active", ch.reload.status
    assert_equal "active", JSON.parse(response.body).dig("custom_domain", "status")
  end

  test "verify surfaces the failure reason verbatim and leaves the row pending" do
    ch = manual_row
    failure = SelfHostedDomainVerificationService::Result.new(active: false, error: "No valid certificate for this host yet")
    SelfHostedDomainVerificationService.stub(:verify, ->(*) { failure }) do
      post "#{API_PREFIX}/projects/#{projects(:one).id}/custom_domains/verify",
           params: { hostname: ch.hostname }, headers: admin_headers
    end

    assert_response :ok
    assert_equal "pending", ch.reload.status
    assert_equal "No valid certificate for this host yet",
                 JSON.parse(response.body).dig("custom_domain", "verification_errors")
  end

  test "verify 404s for a hostname on another project" do
    manual_row
    post "#{API_PREFIX}/projects/#{projects(:one).id}/custom_domains/verify",
         params: { hostname: "not.mine.com" }, headers: admin_headers

    assert_response :not_found
  end

  test "verify refuses a Cloudflare-provisioned row" do
    ch = manual_row
    ch.update_columns(cf_custom_hostname_id: "cf_1")
    post "#{API_PREFIX}/projects/#{projects(:one).id}/custom_domains/verify",
         params: { hostname: ch.hostname }, headers: admin_headers

    assert_response :unprocessable_entity
  end

  test "verify 404s when custom domains are disabled" do
    ch = manual_row
    disable_custom_domains!
    post "#{API_PREFIX}/projects/#{projects(:one).id}/custom_domains/verify",
         params: { hostname: ch.hostname }, headers: admin_headers

    assert_response :not_found
  end

  test "a member can create, verify and delete a custom domain" do
    member = doorkeeper_headers_for(users(:member_user))

    post "#{API_PREFIX}/projects/#{projects(:one).id}/custom_domain",
         params: { hostname: "links.member.com" }, headers: member
    assert_response :created

    SelfHostedDomainVerificationService.stub(:verify, ->(*) { SelfHostedDomainVerificationService::Result.new(active: true) }) do
      post "#{API_PREFIX}/projects/#{projects(:one).id}/custom_domains/verify",
           params: { hostname: "links.member.com" }, headers: member
    end
    assert_response :ok

    delete "#{API_PREFIX}/projects/#{projects(:one).id}/custom_domain", headers: member
    assert_response :ok
  end

  test "a member can still read the custom domain list" do
    get "#{API_PREFIX}/projects/#{projects(:one).id}/custom_domains",
        headers: doorkeeper_headers_for(users(:member_user))

    assert_response :ok
  end
end
