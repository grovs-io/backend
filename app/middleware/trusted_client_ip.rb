require "ipaddr"

# Pins remote_ip to the proxy's real-client header; on a list (ALB X-Forwarded-For) the last entry.
class TrustedClientIp
  def initialize(app)
    @app = app
    header = ENV.fetch("CLIENT_IP_HEADER", "CF-Connecting-IP")
    @rack_key = "HTTP_#{header.upcase.tr('-', '_')}" if header.present?
  end

  def call(env)
    ip = @rack_key && env[@rack_key].to_s.split(",").last&.strip
    env["action_dispatch.remote_ip"] = ip if ip.present? && valid_ip?(ip)
    @app.call(env)
  end

  private

  def valid_ip?(value)
    IPAddr.new(value)
    true
  rescue IPAddr::Error
    false
  end
end
