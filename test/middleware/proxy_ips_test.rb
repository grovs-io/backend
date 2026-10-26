# frozen_string_literal: true

require "test_helper"

class ProxyIpsTest < ActiveSupport::TestCase
  # Documentation addresses (RFC 5737), not real hosts.
  GATEWAY = "203.0.113.10"
  PHONE = "198.51.100.7"

  test "gateway ips from env join the cloudflare scrub list" do
    list = Grovs::ProxyIps.scrubbed({ "CUSTOMER_GATEWAY_IPS" => "#{GATEWAY}, 10.9.8.0/24" })

    assert_includes list, GATEWAY
    assert_includes list, "10.9.8.0/24"
    assert_equal Grovs::ProxyIps::CLOUDFLARE, Grovs::ProxyIps.scrubbed({})
  end

  test "a click through a scrubbed gateway resolves request.ip to the phone, matching the app side" do
    app = ->(env) { [200, {}, [Rack::Request.new(env).ip]] }
    scrubbed = RemoteIpProxyScrubber.filter_middleware.new(app, Grovs::ProxyIps.scrubbed({ "CUSTOMER_GATEWAY_IPS" => GATEWAY }))
    unscrubbed = RemoteIpProxyScrubber.filter_middleware.new(app, Grovs::ProxyIps.scrubbed({}))
    # kamal-proxy is the peer, so REMOTE_ADDR is private and Rack falls through to X-Forwarded-For.
    env = { "REMOTE_ADDR" => "10.0.0.5", "HTTP_X_FORWARDED_FOR" => "#{PHONE}, #{GATEWAY}" }

    assert_equal GATEWAY, unscrubbed.call(Rack::MockRequest.env_for("/", env)).last.first
    assert_equal PHONE, scrubbed.call(Rack::MockRequest.env_for("/", env)).last.first
  end
end
