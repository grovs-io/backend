require "ipaddr"

# Pins remote_ip to the proxy's real-client header; on a list (ALB X-Forwarded-For) the last entry.
class TrustedClientIp
  PROXY_IP_HEADER = "HTTP_X_GROVS_CLIENT_IP".freeze
  PROXY_AUTH_HEADER = "HTTP_X_GROVS_PROXY_AUTH".freeze
  # Auth routes the dashboard proxies; audited routes outside these keep the proxy's egress IP.
  PROXIED_PATHS = ["/oauth/", "/api/v1/users", "/api/v1/identity/sso/"].freeze

  def initialize(app)
    @app = app
    header = ENV.fetch("CLIENT_IP_HEADER", "CF-Connecting-IP")
    @rack_key = "HTTP_#{header.upcase.tr('-', '_')}" if header.present?
  end

  def call(env)
    ip = proxied_client_ip(env) || trusted_header_ip(env)
    env["action_dispatch.remote_ip"] = ip if ip
    @app.call(env)
  end

  private

  def trusted_header_ip(env)
    ip = @rack_key && env[@rack_key].to_s.split(",").last&.strip
    ip if ip.present? && valid_ip?(ip)
  end

  # A server-side caller (the dashboard proxies auth) asserting the end user's IP; the shared secret is the proof.
  def proxied_client_ip(env)
    ip = env[PROXY_IP_HEADER].to_s.strip
    return nil if ip.empty? || !proxied_path?(env) || !authenticated_proxy?(env)
    return ip if valid_ip?(ip)

    # Only warn past the secret check: an unauthenticated header is attacker-triggerable log volume.
    log_warn("#{PROXY_IP_HEADER} is not a bare address: #{ip.inspect}")
    nil
  end

  def proxied_path?(env)
    path = env["PATH_INFO"].to_s
    PROXIED_PATHS.any? { |prefix| path.start_with?(prefix) }
  end

  def authenticated_proxy?(env)
    expected = ENV["TRUSTED_PROXY_SECRET"].to_s
    given = env[PROXY_AUTH_HEADER].to_s
    return false if expected.empty? || given.empty?

    ActiveSupport::SecurityUtils.secure_compare(given, expected)
  end

  # IPAddr accepts CIDR ("203.0.113.0/24"), which would be stored verbatim as a client address.
  def valid_ip?(value)
    return false if value.include?("/")

    IPAddr.new(value)
    true
  rescue IPAddr::Error
    false
  end

  def log_warn(message)
    Rails.logger&.warn("[trusted_client_ip] #{message}")
  end
end
