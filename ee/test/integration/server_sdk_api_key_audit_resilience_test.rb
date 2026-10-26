require "test_helper"
require_relative "../../../test/integration/auth_test_helper"

class ServerSdkApiKeyAuditResilienceTest < ActionDispatch::IntegrationTest
  include AuthTestHelper
  include AuditTestHelper
  include ConstStubHelper

  fixtures :instances, :users, :instance_roles, :projects, :domains, :redirect_configs, :links

  class DownRedis
    def with = yield(self)
    def method_missing(*) = raise(Redis::CannotConnectError, "down")
    def respond_to_missing?(*) = true
  end

  setup do
    @instance = instances(:one)
    @project = @instance.production
    entitle!(@instance)
    clear_keys
  end

  teardown { clear_keys }

  def used_key = "audit:api_key_used:#{@instance.id}:127.0.0.1"
  def clear_keys = REDIS.with { |c| c.del(used_key, "audit:api_key_failed:#{@instance.id}:127.0.0.1") }
  def used_count = AuditEvent.where(instance_id: @instance.id, action: "api_key.used").count

  test "with Redis down every use is audited rather than none" do
    with_const(Object, :REDIS, DownRedis.new) do
      2.times { get "/api/v1/sdk/link/nope", headers: server_sdk_headers_for(@project) }
    end
    assert_response :not_found
    assert_equal 2, used_count
  end

  # Contract check skipped: the failed audit is a deliberate 500, which no contract lists.
  test "a failed audit write gives the day's slot back, so the next request is audited" do
    original = ENV["SKIP_API_CONTRACTS"]
    ENV["SKIP_API_CONTRACTS"] = "true"
    Audit.stub(:record, ->(**) { raise ActiveRecord::StatementInvalid, "audit down" }) do
      get "/api/v1/sdk/link/nope", headers: server_sdk_headers_for(@project)
    end
    assert_response :internal_server_error
    assert_equal 0, REDIS.with { |c| c.exists(used_key) }
    ENV["SKIP_API_CONTRACTS"] = original
    get "/api/v1/sdk/link/nope", headers: server_sdk_headers_for(@project)
    assert_response :not_found
    assert_equal 1, used_count
  ensure
    original.nil? ? ENV.delete("SKIP_API_CONTRACTS") : ENV["SKIP_API_CONTRACTS"] = original
  end

  test "metrics for a missing link, or a link of another project, is 404 Link not found" do
    ["nope", links(:second_link).path].each do |path|
      get "/api/v1/sdk/metrics_for_link/#{path}", headers: server_sdk_headers_for(@project)
      assert_response :not_found
      assert_equal({ "error" => "Link not found" }, JSON.parse(response.body))
    end
  end
end
