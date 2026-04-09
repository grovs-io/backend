module McpAuthentication
  extend ActiveSupport::Concern
  include McpUrlHelper

  included do
    before_action :authenticate_mcp_token!, except: [:approve_consent, :list_tokens, :revoke_token_by_id]
  end

  # Override ApplicationController#current_user which falls through to Doorkeeper:
  #   @current_user ||= doorkeeper_token && User.find_by(...)
  # MCP routes have no Doorkeeper token, so without this override the fallthrough
  # would call doorkeeper_token on every request, adding unnecessary overhead.
  # authenticate_mcp_token! sets @current_user directly from the MCP token.
  def current_user
    @current_user
  end

  private

  def authenticate_mcp_token!
    token = extract_bearer_token
    unless token
      # No auth attempted — RFC 6750 §3 says do NOT include error= here.
      render_unauthorized("Missing or invalid Authorization header")
      return
    end

    @mcp_token = McpToken.find_by_plain_token(token) # rubocop:disable Rails/DynamicFindBy
    unless @mcp_token
      # Token was sent but invalid/expired/revoked — RFC 6750 §3.1 requires error="invalid_token"
      # so OAuth-aware clients (e.g. MCP TS SDK) know to refresh instead of treating this as a
      # permanent auth failure.
      render_unauthorized("Invalid, revoked, or expired token", error_code: "invalid_token")
      return
    end

    @mcp_token.touch_last_used!
    @current_user = @mcp_token.user
  end

  def render_unauthorized(message, error_code: nil)
    resource_metadata_url = "#{mcp_base_url}/.well-known/oauth-protected-resource"
    params = [
      %(resource_metadata="#{resource_metadata_url}"),
      %(scope="mcp:full")
    ]
    if error_code
      params << %(error="#{error_code}")
      params << %(error_description="#{message}")
    end
    response.headers["WWW-Authenticate"] = "Bearer #{params.join(', ')}"
    render json: { error: message }, status: :unauthorized
  end

  def extract_bearer_token
    header = request.headers["Authorization"]
    return nil unless header&.start_with?("Bearer ")

    header.split(" ", 2).last
  end
end
