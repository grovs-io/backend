require "test_helper"
require_relative "../../auth_test_helper"

class AdminCreateCustomDomainTest < ActionDispatch::IntegrationTest
  include AuthTestHelper

  fixtures :instances, :users, :projects, :domains, :redirect_configs

  ADMIN_KEY = "test-admin-key".freeze

  setup do
    enable_custom_domains!
    REDIS.flushdb
    CustomHostname.delete_all
    @original_admin_key = ENV["ADMIN_API_KEY"]
    ENV["ADMIN_API_KEY"] = ADMIN_KEY
  end

  teardown do
    disable_custom_domains!
    ENV["ADMIN_API_KEY"] = @original_admin_key
  end

  def admin_headers
    { "X-AUTH" => ADMIN_KEY, "Host" => api_host }
  end

  def stub_cf_create(cf_id:, &block)
    CloudflareCustomHostnameService.stub(
      :create,
      { success: true, cf_id: cf_id, status: "pending", ssl_status: "pending_validation" },
      &block
    )
  end

  def without_contract_check
    previous = ENV["SKIP_API_CONTRACTS"]
    ENV["SKIP_API_CONTRACTS"] = "true"
    yield
  ensure
    ENV["SKIP_API_CONTRACTS"] = previous
  end

  test "admin POST without purpose defaults to primary and stamps source=enterprise" do
    stub_cf_create(cf_id: "cf_default") do
      post "#{API_PREFIX}/admin/create_custom_domain",
           params: { project_id: projects(:two).id, hostname: "primary.acme.com" },
           headers: admin_headers
    end
    assert_response :created
    ch = CustomHostname.find_by(hostname: "primary.acme.com")
    assert_not_nil ch
    assert_equal Grovs::Hostnames::PURPOSE_PRIMARY, ch.purpose
    assert_equal "enterprise", ch.source
  end

  test "admin POST with purpose=migration creates a migration-purpose enterprise row" do
    stub_cf_create(cf_id: "cf_mig") do
      post "#{API_PREFIX}/admin/create_custom_domain",
           params: { project_id: projects(:two).id, hostname: "old-branch.acme.com", purpose: "migration" },
           headers: admin_headers
    end
    assert_response :created
    ch = CustomHostname.find_by(hostname: "old-branch.acme.com")
    assert_not_nil ch
    assert_equal Grovs::Hostnames::PURPOSE_MIGRATION, ch.purpose
    assert_equal "enterprise", ch.source

    body = JSON.parse(response.body)
    assert_equal "migration", body.dig("custom_domain", "purpose")
  end

  test "admin POST with unknown purpose returns 422 and creates no row" do
    without_contract_check do
      assert_no_difference("CustomHostname.count") do
        post "#{API_PREFIX}/admin/create_custom_domain",
             params: { project_id: projects(:two).id, hostname: "bogus.acme.com", purpose: "nonsense" },
             headers: admin_headers
      end
    end
    assert_response :unprocessable_entity
    assert_equal "Invalid purpose", JSON.parse(response.body)["error"]
  end

  test "admin POST same-purpose duplicate returns 409" do
    stub_cf_create(cf_id: "cf_first") do
      post "#{API_PREFIX}/admin/create_custom_domain",
           params: { project_id: projects(:two).id, hostname: "primary-a.acme.com" },
           headers: admin_headers
    end
    assert_response :created

    stub_cf_create(cf_id: "cf_dup") do
      post "#{API_PREFIX}/admin/create_custom_domain",
           params: { project_id: projects(:two).id, hostname: "primary-b.acme.com" },
           headers: admin_headers
    end
    assert_response :conflict
  end

  test "admin POST primary then migration on the same project both succeed" do
    stub_cf_create(cf_id: "cf_primary") do
      post "#{API_PREFIX}/admin/create_custom_domain",
           params: { project_id: projects(:two).id, hostname: "new.acme.com" },
           headers: admin_headers
    end
    assert_response :created

    stub_cf_create(cf_id: "cf_migration") do
      post "#{API_PREFIX}/admin/create_custom_domain",
           params: { project_id: projects(:two).id, hostname: "old.acme.com", purpose: "migration" },
           headers: admin_headers
    end
    assert_response :created

    project = projects(:two)
    assert_equal 1, project.custom_hostnames.primary.count
    assert_equal 1, project.custom_hostnames.migration.count
    assert_equal "new.acme.com", project.custom_hostnames.primary.first.hostname
    assert_equal "old.acme.com", project.custom_hostnames.migration.first.hostname
  end
end
