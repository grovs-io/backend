require "test_helper"

class RackAttackHostTest < ActiveSupport::TestCase
  test "reserved_main_host? matches only our own reserved subdomains" do
    assert Rack::Attack.reserved_main_host?("api.sqd.link", Grovs::Subdomains::API)
    assert Rack::Attack.reserved_main_host?("sdk.sqd.link", Grovs::Subdomains::SDK)
    assert Rack::Attack.reserved_main_host?("mcp.sqd.link", Grovs::Subdomains::MCP)

    # Custom customer domains that merely start with a reserved label must NOT match,
    # so they fall through to the general public throttle instead of bypassing it.
    assert_not Rack::Attack.reserved_main_host?("api.acme.com", Grovs::Subdomains::API)
    assert_not Rack::Attack.reserved_main_host?("sdk.acme.com", Grovs::Subdomains::SDK)
    assert_not Rack::Attack.reserved_main_host?("apiary.acme.com", Grovs::Subdomains::API)
    assert_not Rack::Attack.reserved_main_host?(nil, Grovs::Subdomains::API)
    assert_not Rack::Attack.reserved_main_host?("", Grovs::Subdomains::API)
  end

  def stream_request(path, auth, host: "api.sqd.link")
    env = Rack::MockRequest.env_for("http://#{host}#{path}", "HTTP_AUTHORIZATION" => auth)
    Rack::Attack::Request.new(env)
  end

  test "the pull-feed throttle keys one counter per token across route forms and header spacing" do
    plain = Rack::Attack.event_stream_token_key(stream_request("/api/v1/projects/5/event_stream", "Bearer est_abc"))
    assert_not_nil plain
    assert_equal plain, Rack::Attack.event_stream_token_key(stream_request("/api/v1/projects/5/event_stream.json", "Bearer est_abc"))
    assert_equal plain, Rack::Attack.event_stream_token_key(stream_request("/api/v1/projects/5/event_stream", "Bearer   est_abc  "))
    %w[/api/v1/projects/5/event_stream/ /api/v1/projects/5/event_stream// /api/v1//projects/5/event_stream
       /api/v1/projects/5/event_stream.xml /api/v1/projects/5/event_stream.csv /api/v1/projects/5/event_stream.foo-bar
       /api/v1/projects/%35/event_stream /api/v1/projects/gk3%2Dabc/event_stream].each do |path|
      assert_equal plain, Rack::Attack.event_stream_token_key(stream_request(path, "Bearer est_abc")), path
    end
  end

  test "the pull-feed throttle ignores other hosts, other paths and dashboard bearers" do
    assert_nil Rack::Attack.event_stream_token_key(stream_request("/api/v1/projects/5/event_stream", "Bearer est_abc", host: "sdk.sqd.link"))
    assert_nil Rack::Attack.event_stream_token_key(stream_request("/api/v1/projects/5/event_stream_tokens", "Bearer est_abc"))
    assert_nil Rack::Attack.event_stream_token_key(stream_request("/api/v1/projects/5/event_stream", "Bearer doorkeeper-token"))
  end

  test "the audit export throttle keys the same way and no longer matches a bearer that merely contains the prefix" do
    key = Rack::Attack.audit_export_token_key(stream_request("/api/v1/instances/7/audit_events", "Bearer  aet_abc "))
    assert_not_nil key
    assert_equal key, Rack::Attack.audit_export_token_key(stream_request("/api/v1/instances/7/audit_events/head", "Bearer aet_abc"))
    assert_nil Rack::Attack.audit_export_token_key(stream_request("/api/v1/instances/7/audit_events", "Bearer dk_contains_aet_inside"))
    %w[/api/v1/instances/7/audit_events/ /api/v1/instances/7/audit_events// /api/v1//instances/7/audit_events
       /api/v1/instances/7/audit_events.xml /api/v1/instances/7/audit_events/head.csv
       /api/v1/instances/7/audit_events.foo-bar /api/v1/instances/%37/audit_events].each do |path|
      assert_equal key, Rack::Attack.audit_export_token_key(stream_request(path, "Bearer aet_abc")), path
    end
    assert_nil Rack::Attack.audit_export_token_key(stream_request("/api/v1/instances/7/audit_export_tokens", "Bearer aet_abc"))
  end
end
