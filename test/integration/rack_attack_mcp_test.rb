require "test_helper"
require_relative "mcp_auth_test_helper"

# Production registers throttles only in production, so these tests register the real MCP
# buckets (low limits) through the same method production calls.
class RackAttackMcpTest < ActionDispatch::IntegrationTest
  include McpAuthTestHelper

  fixtures :instances, :users, :instance_roles, :projects

  setup do
    @original_enabled = Rack::Attack.enabled
    @original_store = Rack::Attack.cache.store
    @original_responder = Rack::Attack.throttled_responder
    @responder = Rack::Attack::GROVS_THROTTLED_RESPONDER
    Rack::Attack.cache.store = ActiveSupport::Cache::MemoryStore.new
    Rack::Attack.clear_configuration
    Rack::Attack.throttled_responder = @responder
    Rack::Attack.enabled = true

    @matched = []
    @subscription = ActiveSupport::Notifications.subscribe("throttle.rack_attack") do |_, _, _, _, payload|
      @matched << payload[:request].env["rack.attack.matched"]
    end
    @project = projects(:one)
    @list = "#{MCP_PREFIX}/projects/#{@project.hashid}/dashboards/list"
    @query = "#{MCP_PREFIX}/projects/#{@project.hashid}/analytics/query"
  end

  teardown do
    ActiveSupport::Notifications.unsubscribe(@subscription) if @subscription
    Rack::Attack.cache.store = @original_store
    Rack::Attack.clear_configuration
    Rack::Attack.throttled_responder = @original_responder
    Rack::Attack.enabled = @original_enabled
  end

  def headers_for(user) = create_mcp_headers_for(user)

  test "one token is limited on its own, with a JSON 429 an agent can act on" do
    Rack::Attack.register_mcp_throttles!(token_limit: 2, heavy_limit: 100, ip_limit: 100)
    a = headers_for(users(:admin_user))
    b = headers_for(users(:member_user))

    3.times { post @list, headers: a, as: :json }
    assert_response :too_many_requests
    assert_equal "rate_limited", json_response["error_code"]
    assert_operator json_response["retry_after"], :>, 0
    assert_equal json_response["retry_after"].to_s, response.headers["Retry-After"]
    assert_includes @matched, "mcp_data/token"

    post @list, headers: b, as: :json
    assert_response :ok, "another token from the same IP is unaffected"
  end

  test "the same token counts once whatever its spacing, slashes or format suffix" do
    Rack::Attack.register_mcp_throttles!(token_limit: 2, heavy_limit: 100, ip_limit: 100)
    h = headers_for(users(:admin_user))
    token = h["Authorization"].delete_prefix("Bearer ")
    post @list, headers: h, as: :json
    post "#{@list}/", headers: h.merge("Authorization" => "Bearer   #{token} "), as: :json
    post "#{@list}.json", headers: h, as: :json
    assert_response :too_many_requests
  end

  test "heavy routes have their own smaller bucket" do
    Rack::Attack.register_mcp_throttles!(token_limit: 100, heavy_limit: 1, ip_limit: 100)
    h = headers_for(users(:admin_user))
    Clickhouse.stub(:read_enabled?, true) do
      ::Analytics::MetricQueryService.stub(:run, { rows: [] }) do
        2.times { post @query, params: { metric: "installs" }, headers: h, as: :json }
      end
    end
    assert_response :too_many_requests
    assert_includes @matched, "mcp_heavy/token"

    post @list, headers: h, as: :json
    assert_response :ok, "light routes stay open"
  end

  test "random bearer strings still hit the IP ceiling, except from the hosted server's IPs" do
    Rack::Attack.register_mcp_throttles!(token_limit: 100, heavy_limit: 100, ip_limit: 2)
    3.times { post @list, headers: mcp_headers_with_token(SecureRandom.hex(16)), as: :json }
    assert_response :too_many_requests
    assert_includes @matched, "mcp_data/ip"

    @matched.clear
    Rack::Attack.cache.store.clear
    with_env("MCP_PROXY_IPS" => "10.9.9.9, 127.0.0.1") do
      3.times { post @list, headers: headers_for(users(:admin_user)), as: :json }
    end
    assert_response :ok
    assert_not_includes @matched, "mcp_data/ip"
  end

  test "the general IP bucket skips MCP data routes but still covers the OAuth endpoints" do
    req = ->(path) { Rack::Attack::Request.new(Rack::MockRequest.env_for("http://#{MCP_HOST}#{path}", method: "POST", "REMOTE_ADDR" => "1.2.3.4")) }
    assert_nil Rack::Attack.general_ip_key(req.call(@list))
    assert_not_nil Rack::Attack.general_ip_key(req.call("/token"))
    assert_not_nil Rack::Attack.general_ip_key(req.call("/register"))
  end

  test "other throttles keep their 503" do
    env = { "rack.attack.matched" => "mcp_token/ip", "rack.attack.match_data" => { period: 60, epoch_time: 0 } }
    assert_equal 503, @responder.call(Rack::Attack::Request.new(env)).first
  end

  private

  def with_env(vars)
    old = vars.keys.index_with { |k| ENV.fetch(k, nil) }
    vars.each { |k, v| ENV[k] = v }
    yield
  ensure
    old.each { |k, v| ENV[k] = v }
  end
end
