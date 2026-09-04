Rack::Attack.blocklisted_responder = lambda do |_request|
  # Using 503 because it may make attacker think that they have successfully
  # DOSed the site. Rack::Attack returns 403 for blocklists by default
  [ 503, {}, ['Blocked']]
end

Rack::Attack.throttled_responder = lambda do |request|
  # Entra backs off on 429 + Retry-After but quarantines a provisioning job after repeated 5xx.
  if request.env['rack.attack.matched'] == 'scim/token'
    period = request.env['rack.attack.match_data'][:period]
    next [429, { 'Content-Type' => 'application/scim+json', 'Retry-After' => period.to_s },
          [{ schemas: ['urn:ietf:params:scim:api:messages:2.0:Error'], status: '429', detail: 'Too many requests' }.to_json]]
  end

  # 503 so an attacker thinks the site fell over; Rack::Attack returns 429 by default.
  [ 503, {}, ["Server Error\n"]]
end


class Rack::Attack
  # True only when the host is one of OUR reserved subdomains (e.g. api.sqd.link),
  # not a customer custom domain that merely starts with "api" (e.g. api.acme.com).
  # Defined outside the production gate so it is unit-testable.
  def self.reserved_main_host?(host, subdomain)
    return false if host.blank?

    Grovs::Domains.split(host)&.first == subdomain
  end

  # Only enable rate limiting in production — development and staging
  # need unrestricted access for testing and debugging.
  if Rails.env.production?
    throttle('req/ip', limit: 200, period: 1.minute) do |req|
      unless reserved_main_host?(req.host, Grovs::Subdomains::API) ||
             reserved_main_host?(req.host, Grovs::Subdomains::SDK) ||
             req.host&.start_with?('dls')
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

    # SIEM pollers: 60 pulls a minute per token is plenty for a 1000-row page size.
    throttle('audit_export/token', limit: 60, period: 1.minute) do |req|
      if reserved_main_host?(req.host, Grovs::Subdomains::API) && req.path.match?(%r{/api/v1/instances/\w+/audit_events})
        auth = req.env["HTTP_AUTHORIZATION"].to_s
        Digest::SHA256.hexdigest(auth) if auth.include?("aet_")
      end
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

    # 5000/sec: prod-measured (03ff4f4) — carrier NATs exceeded 500/sec in the May incidents
    throttle('sdk-requests/ip', limit: 5000, period: 1.second) do |req|
      if reserved_main_host?(req.host, Grovs::Subdomains::SDK)
        req.ip
      end
    end
  end
end
