require "test_helper"
require Rails.root.join("app/middleware/trusted_client_ip")

class TrustedClientIpTest < ActiveSupport::TestCase
  def remote_ip_seen_by(env)
    seen = nil
    app = lambda do |e|
      seen = ActionDispatch::Request.new(e).remote_ip
      [200, {}, []]
    end
    TrustedClientIp.new(app).call(env)
    seen
  end

  test "default (SaaS) trusts CF-Connecting-IP over a spoofed X-Forwarded-For" do
    env = {
      "HTTP_CF_CONNECTING_IP" => "203.0.113.7",
      "HTTP_X_FORWARDED_FOR" => "1.2.3.4",
      "action_dispatch.remote_ip" => "1.2.3.4"
    }
    assert_equal "203.0.113.7", remote_ip_seen_by(env)
  end

  test "self-hosted can point CLIENT_IP_HEADER at its own proxy header" do
    with_env("CLIENT_IP_HEADER" => "X-Real-IP") do
      env = { "HTTP_X_REAL_IP" => "10.9.8.7", "HTTP_X_FORWARDED_FOR" => "1.2.3.4",
              "action_dispatch.remote_ip" => "1.2.3.4" }
      assert_equal "10.9.8.7", remote_ip_seen_by(env)
    end
  end

  test "ALB-style list header resolves to the last entry, never a client-supplied one" do
    with_env("CLIENT_IP_HEADER" => "X-Forwarded-For") do
      env = { "HTTP_X_FORWARDED_FOR" => "1.2.3.4, 203.0.113.9", "action_dispatch.remote_ip" => "1.2.3.4" }
      assert_equal "203.0.113.9", remote_ip_seen_by(env)
    end
  end

  test "empty CLIENT_IP_HEADER disables the override" do
    with_env("CLIENT_IP_HEADER" => "") do
      env = { "HTTP_CF_CONNECTING_IP" => "203.0.113.7", "action_dispatch.remote_ip" => "1.2.3.4" }
      assert_equal "1.2.3.4", remote_ip_seen_by(env)
    end
  end

  test "leaves remote_ip untouched when the trusted header is absent" do
    env = { "HTTP_X_FORWARDED_FOR" => "9.9.9.9", "action_dispatch.remote_ip" => "9.9.9.9" }
    assert_equal "9.9.9.9", remote_ip_seen_by(env)
  end

  test "ignores a malformed value" do
    env = { "HTTP_CF_CONNECTING_IP" => "not-an-ip", "action_dispatch.remote_ip" => "9.9.9.9" }
    assert_equal "9.9.9.9", remote_ip_seen_by(env)
  end

  def with_env(vars)
    saved = vars.keys.index_with { |k| ENV[k] }
    vars.each { |k, v| ENV[k] = v }
    yield
  ensure
    saved.each { |k, v| ENV[k] = v }
  end

  test "a proxy holding the secret asserts the end user ip over the load balancer's" do
    with_env("CLIENT_IP_HEADER" => "X-Forwarded-For", "TRUSTED_PROXY_SECRET" => "s3cret") do
      env = { "HTTP_X_FORWARDED_FOR" => "10.0.0.5", "PATH_INFO" => "/oauth/token", "HTTP_X_GROVS_CLIENT_IP" => "203.0.113.9",
              "HTTP_X_GROVS_PROXY_AUTH" => "s3cret", "action_dispatch.remote_ip" => "10.0.0.5" }
      assert_equal "203.0.113.9", remote_ip_seen_by(env)
    end
  end

  test "the asserted ip is ignored without the secret" do
    with_env("CLIENT_IP_HEADER" => "X-Forwarded-For", "TRUSTED_PROXY_SECRET" => "s3cret") do
      env = { "HTTP_X_FORWARDED_FOR" => "10.0.0.5", "PATH_INFO" => "/oauth/token", "HTTP_X_GROVS_CLIENT_IP" => "203.0.113.9",
              "action_dispatch.remote_ip" => "10.0.0.5" }
      assert_equal "10.0.0.5", remote_ip_seen_by(env)
    end
  end

  test "the asserted ip is ignored when the secret is wrong" do
    with_env("CLIENT_IP_HEADER" => "X-Forwarded-For", "TRUSTED_PROXY_SECRET" => "s3cret") do
      env = { "HTTP_X_FORWARDED_FOR" => "10.0.0.5", "PATH_INFO" => "/oauth/token", "HTTP_X_GROVS_CLIENT_IP" => "203.0.113.9",
              "HTTP_X_GROVS_PROXY_AUTH" => "wrong", "action_dispatch.remote_ip" => "10.0.0.5" }
      assert_equal "10.0.0.5", remote_ip_seen_by(env)
    end
  end

  test "with no TRUSTED_PROXY_SECRET configured the header is inert" do
    with_env("CLIENT_IP_HEADER" => "X-Forwarded-For", "TRUSTED_PROXY_SECRET" => nil) do
      env = { "HTTP_X_FORWARDED_FOR" => "10.0.0.5", "PATH_INFO" => "/oauth/token", "HTTP_X_GROVS_CLIENT_IP" => "203.0.113.9",
              "HTTP_X_GROVS_PROXY_AUTH" => "", "action_dispatch.remote_ip" => "10.0.0.5" }
      assert_equal "10.0.0.5", remote_ip_seen_by(env)
    end
  end

  test "a CIDR is not an address and is rejected" do
    with_env("CLIENT_IP_HEADER" => "X-Forwarded-For", "TRUSTED_PROXY_SECRET" => "s3cret") do
      env = { "HTTP_X_FORWARDED_FOR" => "10.0.0.5", "PATH_INFO" => "/oauth/token", "HTTP_X_GROVS_CLIENT_IP" => "203.0.113.0/24",
              "HTTP_X_GROVS_PROXY_AUTH" => "s3cret", "action_dispatch.remote_ip" => "10.0.0.5" }
      assert_equal "10.0.0.5", remote_ip_seen_by(env)
    end
  end

  test "a malformed asserted ip is rejected" do
    with_env("CLIENT_IP_HEADER" => "X-Forwarded-For", "TRUSTED_PROXY_SECRET" => "s3cret") do
      env = { "HTTP_X_FORWARDED_FOR" => "10.0.0.5", "PATH_INFO" => "/oauth/token", "HTTP_X_GROVS_CLIENT_IP" => "not-an-ip",
              "HTTP_X_GROVS_PROXY_AUTH" => "s3cret", "action_dispatch.remote_ip" => "10.0.0.5" }
      assert_equal "10.0.0.5", remote_ip_seen_by(env)
    end
  end

  test "a CIDR in the load balancer header is rejected too" do
    with_env("CLIENT_IP_HEADER" => "X-Forwarded-For") do
      env = { "HTTP_X_FORWARDED_FOR" => "203.0.113.0/24", "action_dispatch.remote_ip" => "10.0.0.5" }
      assert_equal "10.0.0.5", remote_ip_seen_by(env)
    end
  end

  test "the asserted ip is ignored outside the proxied auth routes" do
    with_env("CLIENT_IP_HEADER" => "X-Forwarded-For", "TRUSTED_PROXY_SECRET" => "s3cret") do
      env = { "PATH_INFO" => "/api/v1/sdk/events", "HTTP_X_FORWARDED_FOR" => "10.0.0.5",
              "HTTP_X_GROVS_CLIENT_IP" => "203.0.113.9", "HTTP_X_GROVS_PROXY_AUTH" => "s3cret",
              "action_dispatch.remote_ip" => "10.0.0.5" }
      assert_equal "10.0.0.5", remote_ip_seen_by(env)
    end
  end
end
