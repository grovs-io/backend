require "test_helper"
require_relative "auth_test_helper"

class MigrationSourcesApiTest < ActionDispatch::IntegrationTest
  include AuthTestHelper

  fixtures :instances, :users, :instance_roles, :projects, :domains,
           :redirect_configs, :custom_hostnames

  setup do
    enable_migrations!
    REDIS.flushdb
    MigrationSource.delete_all
    @project     = projects(:one)
    @admin       = users(:admin_user)
    @member_only = users(:member_user)
    @ch = custom_hostnames(:acme_active)
    @ch.update_columns(status: "active")
  end

  teardown { disable_migrations! }

  def url
    "#{API_PREFIX}/projects/#{@project.id}/migration_source"
  end

  def admin_headers
    doorkeeper_headers_for(@admin)
  end

  # Form-encoded serializes { enabled: false } as { "enabled" => "false" } and breaks the contract.
  def json_post(path, body, headers: admin_headers)
    post path, params: body.to_json, headers: headers.merge("CONTENT_TYPE" => "application/json")
  end

  def json_patch(path, body, headers: admin_headers)
    patch path, params: body.to_json, headers: headers.merge("CONTENT_TYPE" => "application/json")
  end

  test "legacy POST /migration_source route no longer exists" do
    body = { provider: "branch", old_host: "links.acme.com",
             credentials: { branch_key: "x" } }
    json_post url, body
    assert_response :not_found
  end

  test "non-admin (member) gets 403 on show" do
    get url, headers: doorkeeper_headers_for(@member_only)
    assert_response :forbidden
  end

  test "non-admin (member) gets 403 on test endpoint" do
    MigrationSource.create!(project: @project, old_host: "links.acme.com",
                            provider: "branch", credentials: { "branch_key" => "x" })
    post "#{url}/test", headers: doorkeeper_headers_for(@member_only)
    assert_response :forbidden
  end

  test "test endpoint requires authentication (401)" do
    MigrationSource.create!(project: @project, old_host: "links.acme.com",
                            provider: "branch", credentials: { "branch_key" => "x" })
    post "#{url}/test", headers: api_headers
    assert_response :unauthorized
  end

  test "slice_credentials drops unknown keys for Branch" do
    ctrl = Api::V1::MigrationSourcesController.new
    result = ctrl.send(:slice_credentials,
                       { "branch_key" => "real", "junk" => "x", "exfil" => "y" },
                       Grovs::Migrations::PROVIDER_BRANCH)
    assert_equal({ "branch_key" => "real" }, result)
  end

  test "slice_credentials drops unknown keys for AppsFlyer (no cross-provider leakage)" do
    ctrl = Api::V1::MigrationSourcesController.new
    result = ctrl.send(:slice_credentials,
                       { "onelink_id" => "abc", "api_token" => "tok", "branch_key" => "smuggled" },
                       Grovs::Migrations::PROVIDER_APPSFLYER)
    assert_equal({ "onelink_id" => "abc", "api_token" => "tok" }, result)
  end

  test "slice_credentials accepts ActionController::Parameters input (controller flow)" do
    ctrl = Api::V1::MigrationSourcesController.new
    params = ActionController::Parameters.new(branch_key: "real", junk: "x").permit!
    result = ctrl.send(:slice_credentials, params, Grovs::Migrations::PROVIDER_BRANCH)
    assert_equal({ "branch_key" => "real" }, result)
  end

  def without_contract_check
    previous = ENV["SKIP_API_CONTRACTS"]
    ENV["SKIP_API_CONTRACTS"] = "true"
    yield
  ensure
    ENV["SKIP_API_CONTRACTS"] = previous
  end

  test "update persists ONLY allowlisted credential keys when extra keys are submitted" do
    src = MigrationSource.create!(project: @project, old_host: "links.acme.com",
                                  provider: "branch", credentials: { "branch_key" => "old" })
    without_contract_check do
      json_patch url, { credentials: { branch_key: "new", junk: "y" } }
    end
    assert_response :ok
    assert_equal({ "branch_key" => "new" }, src.reload.credentials)
  end

  test "slice_credentials returns empty hash when input is nil (guarded against non-Hash)" do
    ctrl = Api::V1::MigrationSourcesController.new
    assert_equal({}, ctrl.send(:slice_credentials, nil, Grovs::Migrations::PROVIDER_BRANCH))
  end

  test "slice_credentials returns empty hash when input is a String (non-Hash safety guard)" do
    ctrl = Api::V1::MigrationSourcesController.new
    assert_equal({}, ctrl.send(:slice_credentials, "not-a-hash", Grovs::Migrations::PROVIDER_BRANCH))
  end

  test "PATCH credentials as a String surfaces as 422, not 500" do
    MigrationSource.create!(project: @project, old_host: "links.acme.com",
                            provider: "branch", credentials: { "branch_key" => "old" })
    without_contract_check do
      json_patch url, { credentials: "not-a-hash" }
    end
    # Either 200 (strong-params filtered) or 422 (validator) is fine; no 500 is the point.
    assert_not_equal 500, response.status, "must not crash on non-Hash credentials"
    assert_includes [200, 422], response.status
  end

  test "admin of a DIFFERENT instance cannot access project A's source (403 or 404 — no info leak)" do
    other_admin = users(:super_admin_user)
    get url, headers: doorkeeper_headers_for(other_admin)
    assert_includes [403, 404], response.status,
      "cross-instance admin must NOT see project A's source"
  end

  test "show returns null when not configured" do
    get url, headers: admin_headers
    assert_response :ok
    assert_nil JSON.parse(response.body)["migration_source"]
  end

  test "show returns the source when configured" do
    src = MigrationSource.create!(
      project: @project, old_host: "links.acme.com", provider: "branch",
      credentials: { "branch_key" => "x" }
    )
    get url, headers: admin_headers
    assert_response :ok
    body = JSON.parse(response.body)
    assert_equal src.id, body["migration_source"]["id"]
    assert_not body["migration_source"].key?("credentials")
  end

  test "update flips enabled true→false (200)" do
    src = MigrationSource.create!(project: @project, old_host: "links.acme.com",
                                  provider: "branch", credentials: { "branch_key" => "x" })
    json_patch url, { enabled: false }
    assert_response :ok
    assert_equal false, src.reload.enabled
  end

  test "update credentials resets failure counters" do
    src = MigrationSource.create!(project: @project, old_host: "links.acme.com",
                                  provider: "branch", credentials: { "branch_key" => "old" })
    src.update_columns(consecutive_failures: 50, first_failure_at: 1.hour.ago, last_error_status: 401)
    json_patch url, { credentials: { branch_key: "new" } }
    assert_response :ok
    src.reload
    assert_equal 0, src.consecutive_failures
    assert_nil src.first_failure_at
  end

  test "update returns 404 when no source exists" do
    json_patch url, { enabled: false }
    assert_response :not_found
  end

  test "destroy removes the source and cascades MigratedLink rows" do
    src = MigrationSource.create!(project: @project, old_host: "links.acme.com",
                                  provider: "branch", credentials: { "branch_key" => "x" })
    MigratedLink.create!(migration_source: src, old_path: "p", status: MigratedLink::STATUS_NOT_FOUND, cached_until: 1.hour.from_now)
    assert_difference "MigrationSource.count", -1 do
      assert_difference "MigratedLink.count", -1 do
        delete url, headers: admin_headers
      end
    end
    assert_response :ok
  end

  test "destroy returns 404 when no source exists" do
    delete url, headers: admin_headers
    assert_response :not_found
  end

  test "test endpoint with stubbed 404 from upstream returns credentials_ok and resets counters" do
    src = MigrationSource.create!(project: @project, old_host: "links.acme.com",
                                  provider: "branch", credentials: { "branch_key" => "x" })
    src.update_columns(consecutive_failures: 50, first_failure_at: 1.hour.ago)
    HTTParty.stub(:get, Struct.new(:code, :parsed_response, :headers).new(404, {}, {})) do
      post "#{url}/test", headers: admin_headers
    end
    assert_response :ok
    body = JSON.parse(response.body)
    assert_equal "credentials_ok", body["outcome"]
    assert_equal 0, src.reload.consecutive_failures
  end

  test "test endpoint with stubbed 401 returns credentials_invalid and does NOT reset counters" do
    src = MigrationSource.create!(project: @project, old_host: "links.acme.com",
                                  provider: "branch", credentials: { "branch_key" => "x" })
    src.update_columns(consecutive_failures: 5, first_failure_at: 1.hour.ago)
    HTTParty.stub(:get, Struct.new(:code, :parsed_response, :headers).new(401, {}, {})) do
      post "#{url}/test", headers: admin_headers
    end
    assert_response :ok
    body = JSON.parse(response.body)
    assert_equal "credentials_invalid", body["outcome"]
    assert_equal 5, src.reload.consecutive_failures
  end

  test "test endpoint maps 429 to upstream_rate_limited" do
    MigrationSource.create!(project: @project, old_host: "links.acme.com",
                            provider: "branch", credentials: { "branch_key" => "x" })
    HTTParty.stub(:get, Struct.new(:code, :parsed_response, :headers).new(429, {}, {})) do
      post "#{url}/test", headers: admin_headers
    end
    body = JSON.parse(response.body)
    assert_equal "upstream_rate_limited", body["outcome"]
  end

  test "test endpoint maps 5xx to upstream_unreachable" do
    MigrationSource.create!(project: @project, old_host: "links.acme.com",
                            provider: "branch", credentials: { "branch_key" => "x" })
    HTTParty.stub(:get, Struct.new(:code, :parsed_response, :headers).new(500, {}, {})) do
      post "#{url}/test", headers: admin_headers
    end
    body = JSON.parse(response.body)
    assert_equal "upstream_unreachable", body["outcome"]
  end
end
