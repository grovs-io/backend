class Mcp::OauthMetadataController < ApplicationController
  include McpUrlHelper

  # GET /.well-known/oauth-protected-resource
  def protected_resource
    base_url = mcp_base_url
    render json: {
      resource: base_url,
      authorization_servers: [base_url],
      scopes_supported: ["mcp:full"]
    }
  end

  # GET /.well-known/oauth-authorization-server
  def authorization_server
    base_url = mcp_base_url
    render json: {
      issuer: base_url,
      authorization_endpoint: "#{base_url}/authorize",
      token_endpoint: "#{base_url}/token",
      registration_endpoint: "#{base_url}/register",
      response_types_supported: ["code"],
      grant_types_supported: ["authorization_code", "refresh_token"],
      code_challenge_methods_supported: ["S256"],
      token_endpoint_auth_methods_supported: ["none"],
      scopes_supported: ["mcp:full"]
    }
  end

end
