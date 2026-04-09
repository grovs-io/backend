# Inherits ApplicationController (not BaseController) because approve_consent uses
# Doorkeeper auth and list_tokens/revoke_token_by_id use Doorkeeper auth — both are
# excluded from the MCP token before_action via McpAuthentication's except list.
class Api::V1::Mcp::AuthController < ApplicationController
  include McpAuthentication

  # POST /api/v1/mcp/approve_consent
  # Called by the Next.js consent page after user clicks "Authorize".
  # Protected by Doorkeeper (user is logged into dashboard).
  def approve_consent
    doorkeeper_authorize!
    return if performed?

    redirect_uri = params.require(:redirect_uri)
    client_id = params.require(:client_id)

    user = User.find_by(id: doorkeeper_token[:resource_owner_id])
    unless user
      render json: { error: "User not found" }, status: :unauthorized
      return
    end

    unless params[:code_challenge].present? && params[:code_challenge_method] == "S256"
      render json: { error: "invalid_request", error_description: "PKCE required" }, status: :bad_request
      return
    end

    client = McpClient.find_by(client_id: client_id)
    unless client
      render json: { error: "invalid_client", error_description: "Unknown client_id" }, status: :bad_request
      return
    end

    unless client.valid_redirect_uri?(redirect_uri)
      render json: { error: "invalid_request", error_description: "redirect_uri not registered for this client" }, status: :bad_request
      return
    end

    auth_code = McpAuthorizationCode.generate_for(
      user: user,
      redirect_uri: redirect_uri,
      client_id: client_id,
      code_challenge: params[:code_challenge],
      code_challenge_method: params[:code_challenge_method],
      state: params[:state],
      scope: params[:scope]
    )

    render json: {
      code: auth_code.code,
      redirect_uri: redirect_uri,
      state: params[:state]
    }, status: :ok
  end

  # DELETE /api/v1/mcp/token
  # Self-revoke: revokes the MCP token used in the Authorization header.
  def revoke_token
    @mcp_token.revoke!
    render json: { message: "Token revoked" }, status: :ok
  end

  # GET /api/v1/mcp/status
  def status
    instances = current_user.instances.includes(
      :applications,
      production: [{ domain: :links }, :redirect_config],
      test: [{ domain: :links }, :redirect_config]
    )

    render json: {
      user: { id: current_user.id, email: current_user.email, name: current_user.name },
      instances: McpInstanceStatusSerializer.serialize(instances)
    }, status: :ok
  end

  # GET /api/v1/mcp/validate
  # Lightweight token validity check. Goes through McpAuthentication's before_action,
  # so a valid token returns 200 and an invalid/revoked/expired token returns 401
  # with error="invalid_token" in WWW-Authenticate (RFC 6750 §3.1).
  # Used by the MCP TS server's requireAuth middleware to surface 401s to the
  # OAuth client (Claude Code) so it can trigger refresh. Without this upfront
  # check, invalid-token errors would be swallowed by the MCP tool response layer.
  def validate
    render json: { valid: true }, status: :ok
  end

  # GET /api/v1/mcp/usage?instance_id=...
  # Returns the usage block for a single instance the authenticated user belongs to.
  # Lighter than calling /status when the caller only needs MAU/quota info.
  def usage
    params.require(:instance_id)

    instance = current_user.instances.find_by_hashid(params[:instance_id])
    unless instance
      render json: { error: "Instance not found" }, status: :not_found
      return
    end

    render json: { usage: McpInstanceStatusSerializer.usage_for(instance) }, status: :ok
  rescue ActionController::ParameterMissing => e
    render json: { error: e.message }, status: :bad_request
  end

  # GET /api/v1/mcp/tokens (for dashboard token management)
  # Protected by Doorkeeper (user is logged into dashboard).
  def list_tokens
    doorkeeper_authorize!
    return if performed?

    user = User.find_by(id: doorkeeper_token[:resource_owner_id])
    tokens = McpToken.where(user: user).connected.order(created_at: :desc).to_a
    clients = resolve_client_names(tokens)
    render json: {
      tokens: tokens.map do |t|
        {
          id: t.hashid,
          name: clients[t.client_id] || t.name,
          client_id: t.client_id,
          created_at: t.created_at,
          last_used_at: t.last_used_at
        }
      end
    }, status: :ok
  end

  # DELETE /api/v1/mcp/tokens/:id
  # Revoke a specific token by ID (for dashboard token management).
  # Protected by Doorkeeper (user is logged into dashboard).
  def revoke_token_by_id
    doorkeeper_authorize!
    return if performed?

    user = User.find_by(id: doorkeeper_token[:resource_owner_id])
    token = McpToken.connected.where(user: user).find_by_hashid(params[:id])

    unless token
      render json: { error: "Token not found" }, status: :not_found
      return
    end

    token.revoke!
    render json: { message: "Token revoked" }, status: :ok
  end

  private

  # Tokens created before the client_name fix have the UUID as name.
  # Batch-load client names to avoid N+1 queries.
  def resolve_client_names(tokens)
    uuid_client_ids = tokens.select { |t| t.name == t.client_id }.map(&:client_id).uniq
    return {} if uuid_client_ids.empty?

    McpClient.where(client_id: uuid_client_ids).pluck(:client_id, :client_name).to_h
  end
end
