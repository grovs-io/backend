require "test_helper"
require_relative "auth_test_helper"

class AdminCustomDomainTest < ActionDispatch::IntegrationTest
  include AuthTestHelper

  fixtures :instances, :users, :projects, :domains, :redirect_configs

  ADMIN_KEY = "test-admin-key".freeze

  setup do
    enable_custom_domains!
    REDIS.flushdb
    CustomHostname.delete_all
    @original_admin_key = ENV["ADMIN_API_KEY"]
    ENV["ADMIN_API_KEY"] = ADMIN_KEY # self-contained: don't depend on ambient .env
  end
  teardown do
    disable_custom_domains!
    ENV["ADMIN_API_KEY"] = @original_admin_key
  end

  def admin_headers
    { "X-AUTH" => ADMIN_KEY, "Host" => api_host }
  end

  test "admin creates an enterprise custom domain, bypassing subscription entitlement" do
    # projects(:two) belongs to the un-entitled instance two; admin can still provision.
    CloudflareCustomHostnameService.stub(:create, { success: true, cf_id: "cf_ent", status: "pending", ssl_status: "pending_validation" }) do
      post "#{API_PREFIX}/admin/create_custom_domain",
           params: { project_id: projects(:two).id, hostname: "links.enterprise-x.com" },
           headers: admin_headers
    end
    assert_response :created
    ch = CustomHostname.find_by(hostname: "links.enterprise-x.com")
    assert_not_nil ch
    assert_equal "enterprise", ch.source
  end

  test "rejects bad admin credentials" do
    post "#{API_PREFIX}/admin/create_custom_domain",
         params: { project_id: projects(:two).id, hostname: "links.x.com" },
         headers: { "X-AUTH" => "wrong", "Host" => api_host }
    assert_response :forbidden
  end

  test "returns 404 when the feature is disabled" do
    disable_custom_domains!
    post "#{API_PREFIX}/admin/create_custom_domain",
         params: { project_id: projects(:two).id, hostname: "links.x.com" },
         headers: admin_headers
    assert_response :not_found
  end
end
