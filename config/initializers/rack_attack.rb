Rack::Attack.blocklisted_responder = lambda do |_request|
  # Using 503 because it may make attacker think that they have successfully
  # DOSed the site. Rack::Attack returns 403 for blocklists by default
  [ 503, {}, ['Blocked']]
end

Rack::Attack::GROVS_THROTTLED_RESPONDER = lambda do |request|
  # Entra backs off on 429 + Retry-After but quarantines a provisioning job after repeated 5xx.
  if request.env['rack.attack.matched'] == 'scim/token'
    period = request.env['rack.attack.match_data'][:period]
    next [429, { 'Content-Type' => 'application/scim+json', 'Retry-After' => period.to_s },
          [{ schemas: ['urn:ietf:params:scim:api:messages:2.0:Error'], status: '429', detail: 'Too many requests' }.to_json]]
  end

  # MCP and server API clients are agents: a JSON 429 with Retry-After tells them to wait, not retry in a loop.
  if Rack::Attack::JSON_THROTTLES.include?(request.env['rack.attack.matched'])
    data = request.env['rack.attack.match_data']
    retry_after = data[:period] - (data[:epoch_time] % data[:period])
    next [429, { 'Content-Type' => 'application/json', 'Retry-After' => retry_after.to_s },
          [{ error: "Rate limit exceeded; retry in #{retry_after}s", error_code: 'rate_limited', retry_after: retry_after }.to_json]]
  end

  # 503 so an attacker thinks the site fell over; Rack::Attack returns 429 by default.
  [ 503, {}, ["Server Error\n"]]
end
Rack::Attack.throttled_responder = Rack::Attack::GROVS_THROTTLED_RESPONDER


class Rack::Attack
  # True only when the host is one of OUR reserved subdomains (e.g. api.sqd.link),
  # not a customer custom domain that merely starts with "api" (e.g. api.acme.com).
  # Defined outside the production gate so it is unit-testable.
  def self.reserved_main_host?(host, subdomain)
    return false if host.blank?

    Grovs::Domains.split(host)&.first == subdomain
  end

  # One counter per token, whatever the route's format suffix, slashes or the header's spacing.
  def self.prefixed_token_key(req, path_regex, prefix)
    return nil unless reserved_main_host?(req.host, Grovs::Subdomains::API)
    return nil unless normalized_path(req).match?(path_regex)

    token = req.env["HTTP_AUTHORIZATION"].to_s.sub(/\ABearer\s+/i, "").strip
    return nil unless token.start_with?(prefix)

    Digest::SHA256.hexdigest(token)
  end

  # Match what the router matches: Journey collapses repeated slashes and drops a trailing one,
  # and a format segment is anything up to the next slash.
  def self.normalized_path(req)
    ActionDispatch::Journey::Router::Utils.normalize_path(req.path)
  rescue StandardError
    req.path.to_s
  end

  # `[^/.]+` is the router's own id segment: it also covers a percent-encoded id, which Rails decodes.
  EVENT_STREAM_PATH = %r{\A/api/v1/projects/[^/.]+/event_stream(\.[^/]+)?\z}
  AUDIT_EVENTS_PATH = %r{\A/api/v1/instances/[^/.]+/audit_events(/head)?(\.[^/]+)?\z}

  def self.event_stream_token_key(req) = prefixed_token_key(req, EVENT_STREAM_PATH, "est_")
  def self.audit_export_token_key(req) = prefixed_token_key(req, AUDIT_EVENTS_PATH, "aet_")

  MCP_DATA_PATH = %r{\A/api/v1/mcp/}
  MCP_HEAVY_PATH = %r{\A/api/v1/mcp/(analytics/|projects/[^/.]+/(analytics/|segments|push_campaigns/[^/.]+/experiment|
                     in_app_campaigns/[^/.]+/(report|experiment|comments)|journeys/[^/.]+/report))}x
  # Throttles that answer a JSON 429 with Retry-After.
  JSON_THROTTLES = %w[mcp_data/token mcp_heavy/token mcp_data/ip server_api/key].freeze
  SERVER_API_PATH = %r{\A/api/v1/sdk/server/(segments|in_app_campaigns)(/|\.|\z)}

  def self.mcp_data_request?(req)
    reserved_main_host?(req.host, Grovs::Subdomains::MCP) && normalized_path(req).match?(MCP_DATA_PATH)
  end

  def self.mcp_token_key(req)
    return nil unless mcp_data_request?(req)

    token = req.env["HTTP_AUTHORIZATION"].to_s.sub(/\ABearer\s+/i, "").strip
    token.empty? ? nil : Digest::SHA256.hexdigest(token)
  end

  # The hosted MCP server calls from these IPs for every user, so only direct callers get the IP ceiling.
  def self.mcp_proxy_ip?(req) = ENV.fetch("MCP_PROXY_IPS", "").split(",").map(&:strip).include?(req.ip)

  # Every caller outside the API, SDK and link hosts; MCP data routes have their own buckets below.
  def self.general_ip_key(req)
    return nil if reserved_main_host?(req.host, Grovs::Subdomains::API) || reserved_main_host?(req.host, Grovs::Subdomains::SDK)
    return nil if req.host&.start_with?('dls') || mcp_data_request?(req)

    req.ip
  end

  def self.register_mcp_throttles!(token_limit: 120, heavy_limit: 30, ip_limit: 2000)
    throttle('mcp_data/token', limit: token_limit, period: 1.minute) { |req| mcp_token_key(req) }
    throttle('mcp_heavy/token', limit: heavy_limit, period: 1.minute) do |req|
      mcp_token_key(req) if normalized_path(req).match?(MCP_HEAVY_PATH)
    end
    throttle('mcp_data/ip', limit: ip_limit, period: 1.minute) do |req|
      req.ip if mcp_data_request?(req) && !mcp_proxy_ip?(req)
    end
  end

  def self.server_api_key(req)
    return nil unless reserved_main_host?(req.host, Grovs::Subdomains::SDK) && normalized_path(req).match?(SERVER_API_PATH)

    key = req.env["HTTP_PROJECT_KEY"].to_s.strip
    key.empty? ? nil : Digest::SHA256.hexdigest(key)
  end

  def self.register_server_api_throttle!(limit: 120)
    throttle('server_api/key', limit: limit, period: 1.minute) { |req| server_api_key(req) }
  end

  # Only enable rate limiting in production — development and staging
  # need unrestricted access for testing and debugging.
  if Rails.env.production?
    throttle('req/ip', limit: 200, period: 1.minute) { |req| general_ip_key(req) }
    register_mcp_throttles!
    register_server_api_throttle!

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
      if reserved_main_host?(req.host, Grovs::Subdomains::API) &&
         (req.post? || req.put?) &&
         (["/api/v1/users/reset_password", "/api/v1/users", "/api/v1/users/otp_status"].include?(req.path) ||
          req.path.match?(%r{\A/api/v1/instances/\w+/sso_connection(/|\z)}))
        req.ip
      end
    end

    # Office NATs share one egress and discover fires per email blur; 10/min would 503 a rush.
    throttle('sso/ip', limit: 60, period: 1.minute) do |req|
      if req.path.start_with?("/api/v1/identity/sso/discover", "/api/v1/identity/sso/auth/oidc") &&
         !req.path.end_with?("/callback")
        req.ip
      end
    end

    throttle('scim/token', limit: 600, period: 1.minute) do |req|
      if reserved_main_host?(req.host, Grovs::Subdomains::API) && req.path.start_with?("/scim/v2/")
        Digest::SHA256.hexdigest(req.env["HTTP_AUTHORIZATION"].to_s)
      end
    end

    # MCP token exchange (mcp subdomain)
    throttle('mcp_token/ip', limit: 20, period: 1.minute) do |req|
      if reserved_main_host?(req.host, Grovs::Subdomains::MCP) &&
         req.post? && req.path == "/token"
        req.ip
      end
    end

    # MCP client registration — stricter limit (unauthenticated, creates DB rows)
    throttle('mcp_register/ip', limit: 5, period: 1.minute) do |req|
      if reserved_main_host?(req.host, Grovs::Subdomains::MCP) &&
         req.post? && req.path == "/register"
        req.ip
      end
    end

    # MCP authorize (GET, triggers consent redirect — limit to prevent enumeration)
    throttle('mcp_authorize/ip', limit: 20, period: 1.minute) do |req|
      if reserved_main_host?(req.host, Grovs::Subdomains::MCP) &&
         req.get? && req.path == "/authorize"
        req.ip
      end
    end

    # MCP consent (api subdomain, Doorkeeper-protected)
    throttle('mcp_consent/ip', limit: 10, period: 1.minute) do |req|
      if reserved_main_host?(req.host, Grovs::Subdomains::API) &&
         req.post? &&
         req.path == "/api/v1/mcp/approve_consent"
        req.ip
      end
    end

    # Dashboard bursts (overview+events+autocomplete+scroll) legitimately exceed 60/min
    throttle('analytics/ip', limit: 200, period: 1.minute) do |req|
      if reserved_main_host?(req.host, Grovs::Subdomains::API) &&
         req.get? &&
         req.path.match?(%r{/api/v1/projects/\w+/analytics/})
        req.ip
      end
    end

    throttle('admin/ip', limit: 5000, period: 1.minute) do |req|
      if reserved_main_host?(req.host, Grovs::Subdomains::API) &&
         (req.path.start_with?("/api/v1/admin/") || req.path.start_with?("/api/v1/automation/"))
        req.ip
      end
    end

    # Pull-feed clients poll continuously; this bounds one token, not the dashboard's own reads.
    throttle('event_stream/token', limit: 120, period: 1.minute) do |req|
      event_stream_token_key(req)
    end

    # SIEM pollers: 60 pulls a minute per token is plenty for a 1000-row page size.
    throttle('audit_export/token', limit: 60, period: 1.minute) do |req|
      audit_export_token_key(req)
    end

    # /api/v1/projects/:id/migration_source/test triggers a synchronous outbound HTTP call
    # to Branch/AppsFlyer per request. Admin-gated, but an admin (or compromised session)
    # could hammer it to amplify outbound traffic, consume the customer's upstream quota,
    # and trip rate-limit penalties on their behalf. 5/min/IP is plenty for legit setup
    # validation but kills the amplification vector.
    throttle('migration-source-test/ip', limit: 5, period: 1.minute) do |req|
      if reserved_main_host?(req.host, Grovs::Subdomains::API) &&
         req.path =~ %r{\A/api/v1/projects/[^/]+/migration_source/test\z}
        req.ip
      end
    end

    throttle('diagnostics/ip', limit: 60, period: 1.minute) do |req|
      req.ip if req.path.start_with?('/api/v1/diagnostics/')
    end

    # 5000/sec: prod-measured (03ff4f4) — carrier NATs exceeded 500/sec in the May incidents
    throttle('sdk-requests/ip', limit: 5000, period: 1.second) do |req|
      if reserved_main_host?(req.host, Grovs::Subdomains::SDK)
        req.ip
      end
    end
  end
end
