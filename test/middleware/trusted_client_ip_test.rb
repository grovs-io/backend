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
end
