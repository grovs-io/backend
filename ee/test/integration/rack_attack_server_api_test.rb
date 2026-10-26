require "test_helper"
require_relative "../../../test/integration/auth_test_helper"

class RackAttackServerApiTest < ActionDispatch::IntegrationTest
  include AuthTestHelper
  include AuditTestHelper

  fixtures :instances, :users, :instance_roles, :projects, :domains, :redirect_configs

  setup do
    @original_enabled = Rack::Attack.enabled
    @original_store = Rack::Attack.cache.store
    @original_responder = Rack::Attack.throttled_responder
    Rack::Attack.cache.store = ActiveSupport::Cache::MemoryStore.new
    Rack::Attack.clear_configuration
    Rack::Attack.throttled_responder = Rack::Attack::GROVS_THROTTLED_RESPONDER
    Rack::Attack.enabled = true
    # Throttles register only in production; this registers the real bucket with a low limit.
    Rack::Attack.register_server_api_throttle!(limit: 2)

    @project = projects(:one)
    entitle!(@project.instance)
    entitle!(projects(:two).instance)
    @headers = server_sdk_headers_for(@project)
    @base = "#{SDK_PREFIX}/server/segments"
  end

  teardown do
    Rack::Attack.cache.store = @original_store
    Rack::Attack.clear_configuration
    Rack::Attack.throttled_responder = @original_responder
    Rack::Attack.enabled = @original_enabled
  end

  test "one key is limited with a JSON 429 and Retry-After; another key and the dashboard are not" do
    get @base, headers: @headers
    get "#{SDK_PREFIX}/server/in_app_campaigns", headers: @headers
    get "#{@base}.json", headers: @headers
    assert_response :too_many_requests
    assert_equal "rate_limited", response.parsed_body["error_code"]
    assert_operator response.parsed_body["retry_after"], :>, 0
    assert_equal response.parsed_body["retry_after"].to_s, response.headers["Retry-After"]

    get @base, headers: server_sdk_headers_for(projects(:two))
    assert_response :ok, "another key has its own bucket"

    3.times { get "#{API_PREFIX}/projects/#{@project.id}/segments", headers: doorkeeper_headers_for(users(:member_user)) }
    assert_response :ok, "dashboard routes are not in the bucket"

    get "#{SDK_PREFIX}/link/nope", headers: @headers
    assert_response :not_found, "other server SDK routes are not in the bucket"
  end
end
