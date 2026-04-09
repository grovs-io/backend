Rack::Attack.blocklisted_responder = lambda do |_request|
  # Using 503 because it may make attacker think that they have successfully
  # DOSed the site. Rack::Attack returns 403 for blocklists by default
  [ 503, {}, ['Blocked']]
end

Rack::Attack.throttled_responder = lambda do |_request|
  # NB: you have access to the name and other data about the matched throttle
  #  request.env['rack.attack.matched'],
  #  request.env['rack.attack.match_type'],
  #  request.env['rack.attack.match_data'],
  #  request.env['rack.attack.match_discriminator']

  # Using 503 because it may make attacker think that they have successfully
  # DOSed the site. Rack::Attack returns 429 for throttling by default
  [ 503, {}, ["Server Error\n"]]
end


class Rack::Attack
  # Only enable rate limiting in production — development and staging
  # need unrestricted access for testing and debugging.
  if Rails.env.production?
    throttle('req/ip', limit: 200, period: 1.minute) do |req|
      unless req.host&.start_with?(Grovs::Subdomains::API) || req.host&.start_with?('dls')
        req.ip
      end
    end

    throttle('logins/ip', limit: 20, period: 1.minute) do |req|
      req.ip if req.path == "/oauth/token" && req.post?
    end

    throttle('logins/email', limit: 10, period: 1.minute) do |req|
      if req.path == "/oauth/token" && req.post?
        req.params["email"]&.to_s&.downcase&.strip.presence
      end
    end

    # Unauthenticated endpoints that could be used for email enumeration
    throttle('sensitive/ip', limit: 10, period: 1.minute) do |req|
      if req.host&.start_with?(Grovs::Subdomains::API) &&
         req.post? &&
         ["/api/v1/users/reset_password", "/api/v1/users", "/api/v1/users/otp_status"].include?(req.path)
        req.ip
      end
    end

    # MCP token exchange (mcp subdomain)
    throttle('mcp_token/ip', limit: 20, period: 1.minute) do |req|
      if req.host&.start_with?(Grovs::Subdomains::MCP) &&
         req.post? && req.path == "/token"
        req.ip
      end
    end

    # MCP client registration — stricter limit (unauthenticated, creates DB rows)
    throttle('mcp_register/ip', limit: 5, period: 1.minute) do |req|
      if req.host&.start_with?(Grovs::Subdomains::MCP) &&
         req.post? && req.path == "/register"
        req.ip
      end
    end

    # MCP authorize (GET, triggers consent redirect — limit to prevent enumeration)
    throttle('mcp_authorize/ip', limit: 20, period: 1.minute) do |req|
      if req.host&.start_with?(Grovs::Subdomains::MCP) &&
         req.get? && req.path == "/authorize"
        req.ip
      end
    end

    # MCP consent (api subdomain, Doorkeeper-protected)
    throttle('mcp_consent/ip', limit: 10, period: 1.minute) do |req|
      if req.host&.start_with?(Grovs::Subdomains::API) &&
         req.post? &&
         req.path == "/api/v1/mcp/approve_consent"
        req.ip
      end
    end

    throttle('admin/ip', limit: 5000, period: 1.minute) do |req|
      if req.host&.start_with?(Grovs::Subdomains::API) &&
         (req.path.start_with?("/api/v1/admin/") || req.path.start_with?("/api/v1/automation/"))
        req.ip
      end
    end

    throttle('sdk-requests/ip', limit: 200, period: 1.second) do |req|
      if req.host&.start_with?(Grovs::Subdomains::SDK)
        req.ip
      end
    end
  end
end