class Mcp::TokenController < ApplicationController
  # POST /token
  def create
    grant_type = params[:grant_type]

    case grant_type
    when "authorization_code"
      handle_authorization_code
    when "refresh_token"
      handle_refresh_token
    else
      render json: { error: "unsupported_grant_type" }, status: :bad_request
    end
  end

  private

  def handle_authorization_code
    code = params[:code]
    redirect_uri = params[:redirect_uri]
    client_id = params[:client_id]
    code_verifier = params[:code_verifier]

    auth_code = McpAuthorizationCode.exchange(
      code: code,
      redirect_uri: redirect_uri,
      client_id: client_id
    )

    unless auth_code
      render json: { error: "invalid_grant", error_description: "Invalid, expired, or already-used authorization code" }, status: :bad_request
      return
    end

    # Verify PKCE (mandatory for all public clients per OAuth 2.1)
    unless auth_code.code_challenge.present?
      render json: { error: "invalid_grant", error_description: "PKCE required" }, status: :bad_request
      return
    end

    unless verify_pkce(code_verifier, auth_code.code_challenge, auth_code.code_challenge_method)
      render json: { error: "invalid_grant", error_description: "PKCE verification failed" }, status: :bad_request
      return
    end

    client = McpClient.find_by(client_id: client_id)
    mcp_token = McpToken.new(
      user: auth_code.user,
      name: client&.client_name || client_id || "MCP Token",
      client_id: client_id,
      scope: auth_code.scope
    )
    plain_access = mcp_token.generate_token
    mcp_token.save!

    render json: {
      access_token: plain_access,
      token_type: "Bearer",
      expires_in: McpToken::MCP_TOKEN_TTL.to_i,
      refresh_token: mcp_token.plain_refresh_token,
      scope: mcp_token.scope
    }, status: :ok
  end

  def handle_refresh_token
    refresh_token = params[:refresh_token]
    client_id = params[:client_id]

    existing = McpToken.find_by_refresh_token(refresh_token) # rubocop:disable Rails/DynamicFindBy
    unless existing
      render json: { error: "invalid_grant", error_description: "Invalid refresh token" }, status: :bad_request
      return
    end

    # Refresh token is bound to the client that obtained it (OAuth 2.1)
    if client_id.present? && existing.client_id.present? && client_id != existing.client_id
      render json: { error: "invalid_grant", error_description: "client_id mismatch" }, status: :bad_request
      return
    end

    # Rotate: revoke old token, issue new access + refresh pair.
    # Note: each refresh resets the 90-day refresh TTL (sliding window).
    # This is intentional — active clients maintain access indefinitely.
    # Inactive clients (no refresh within 90 days) are expired.
    new_token = McpToken.new(
      user: existing.user,
      name: existing.name,
      client_id: existing.client_id,
      scope: existing.scope
    )
    plain_access = new_token.generate_token
    new_token.save!

    # Revoke old token
    existing.revoke!

    render json: {
      access_token: plain_access,
      token_type: "Bearer",
      expires_in: McpToken::MCP_TOKEN_TTL.to_i,
      refresh_token: new_token.plain_refresh_token,
      scope: new_token.scope
    }, status: :ok
  end

  def verify_pkce(verifier, challenge, method)
    return false if verifier.blank?

    case method
    when "S256"
      computed = Base64.urlsafe_encode64(Digest::SHA256.digest(verifier), padding: false)
      ActiveSupport::SecurityUtils.secure_compare(computed, challenge)
    else
      false # Only S256 supported
    end
  end
end
