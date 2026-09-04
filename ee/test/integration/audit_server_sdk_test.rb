require "test_helper"
require_relative "../../../test/integration/auth_test_helper"

class AuditServerSdkTest < ActionDispatch::IntegrationTest
  include AuthTestHelper
  include AuditTestHelper

  fixtures :instances, :users, :instance_roles, :projects, :domains, :redirect_configs

  setup do
    @instance = instances(:one)
    @project = @instance.production
    entitle!(@instance)
    clear_keys
  end

  teardown { clear_keys }

  def clear_keys
    REDIS.with { |c| c.del("audit:api_key_used:#{@instance.id}:127.0.0.1", "audit:api_key_failed:#{@instance.id}:127.0.0.1") }
  end

  test "first use from an ip is audited once per day, links are not" do
    2.times do
      get "/api/v1/sdk/link/nope", headers: server_sdk_headers_for(@project)
    end
    assert_equal 1, AuditEvent.where(instance_id: @instance.id, action: "api_key.used").count
    assert_equal 0, AuditEvent.where(instance_id: @instance.id, action: "link.created").count
    ev = AuditEvent.find_by(instance_id: @instance.id, action: "api_key.used")
    assert_equal "api_key", ev.actor["type"]
    assert_equal "127.0.0.1", ev.ip
  end

  test "known key with bad environment is audited as auth_failed once per day" do
    2.times { get "/api/v1/sdk/link/x", headers: server_sdk_headers_for(@project, environment: "staging") }
    assert_response :bad_request
    assert_equal 1, AuditEvent.where(instance_id: @instance.id, action: "api_key.auth_failed").count
  end

  test "unknown key writes nothing" do
    get "/api/v1/sdk/link/x", headers: server_sdk_headers_for(@project).merge("PROJECT-KEY" => "bogus")
    assert_response :forbidden
    assert_equal 0, AuditEvent.count
  end
end
