require "test_helper"
require_relative "../auth_test_helper"
require_relative "../mcp_auth_test_helper"

# Full end-to-end OAuth 2.1 flow test.
# Walks through the entire spec from an MCP client's perspective:
# discovery → register → PKCE → authorize → consent → token → use → refresh → revoke.
# Schema-validated at every response.
class McpOauthFlowTest < ActionDispatch::IntegrationTest
  include AuthTestHelper
  include McpAuthTestHelper

  MCP_HOST = "mcp.example.com"

  fixtures :instances, :users, :instance_roles, :projects, :domains,
           :redirect_configs, :links, :applications,
           :ios_configurations, :android_configurations, :web_configurations

  setup do
    @admin_user = users(:admin_user)
  end

  test "full OAuth 2.1 flow: discovery → register → authorize → consent → token → use → refresh → revoke" do
    # 1. Discovery: protected resource metadata
    get "/.well-known/oauth-protected-resource", headers: { "Host" => MCP_HOST }
    assert_response :ok
    resource_meta = assert_response_schema(:protected_resource_metadata)
    auth_server = resource_meta["authorization_servers"].first

    # 2. Discovery: authorization server metadata
    get "/.well-known/oauth-authorization-server", headers: { "Host" => MCP_HOST }
    assert_response :ok
    as_meta = assert_response_schema(:authorization_server_metadata)
    assert as_meta["registration_endpoint"].present?
    assert_includes as_meta["code_challenge_methods_supported"], "S256"

    # 3. Dynamic client registration
    post "/register",
      params: {
        client_name: "Claude Desktop",
        redirect_uris: ["http://localhost:3456/callback"],
        application_type: "native"
      },
      headers: { "Host" => MCP_HOST },
      as: :json
    assert_response :created
    client = assert_response_schema(:client_registration)
    client_id = client["client_id"]

    # 4. Generate PKCE
    code_verifier = SecureRandom.urlsafe_base64(32)
    code_challenge = Base64.urlsafe_encode64(
      Digest::SHA256.digest(code_verifier), padding: false
    )

    # 5. Authorize request → redirects to consent page
    get "/authorize",
      params: {
        client_id: client_id,
        redirect_uri: "http://localhost:3456/callback",
        response_type: "code",
        code_challenge: code_challenge,
        code_challenge_method: "S256",
        state: "test-state-123",
        scope: "mcp:full"
      },
      headers: { "Host" => MCP_HOST }
    assert_response :redirect
    location = response.headers["Location"]
    assert location.present?, "should redirect to consent page"

    # 6. User approves via consent page → frontend calls approve_consent
    doorkeeper_h = doorkeeper_headers_for(@admin_user)
    post "/api/v1/mcp/approve_consent",
      params: {
        client_id: client_id,
        redirect_uri: "http://localhost:3456/callback",
        code_challenge: code_challenge,
        code_challenge_method: "S256",
        state: "test-state-123",
        scope: "mcp:full"
      },
      headers: doorkeeper_h
    assert_response :ok
    consent = assert_response_schema(:consent_response)
    auth_code = consent["code"]
    assert_equal "test-state-123", consent["state"]

    # 7. Exchange code for token with PKCE verifier
    post "/token",
      params: {
        grant_type: "authorization_code",
        code: auth_code,
        redirect_uri: "http://localhost:3456/callback",
        client_id: client_id,
        code_verifier: code_verifier
      },
      headers: { "Host" => MCP_HOST },
      as: :json
    assert_response :ok
    token_json = assert_response_schema(:token_response)
    access_token = token_json["access_token"]
    refresh_token = token_json["refresh_token"]
    assert_equal "Bearer", token_json["token_type"]
    assert_equal McpToken::MCP_TOKEN_TTL.to_i, token_json["expires_in"]

    # 8. Use access token to call MCP API
    get "/api/v1/mcp/status",
      headers: {
        "Authorization" => "Bearer #{access_token}",
        "Host" => MCP_HOST
      }
    assert_response :ok
    status = assert_response_schema(:status_response)
    assert_equal @admin_user.email, status["user"]["email"]

    # 9. Refresh the token
    post "/token",
      params: {
        grant_type: "refresh_token",
        refresh_token: refresh_token,
        client_id: client_id
      },
      headers: { "Host" => MCP_HOST },
      as: :json
    assert_response :ok
    refresh_json = assert_response_schema(:token_response)
    new_access = refresh_json["access_token"]
    new_refresh = refresh_json["refresh_token"]
    assert_not_equal access_token, new_access, "new access token should differ"
    assert_not_equal refresh_token, new_refresh, "new refresh token should differ (rotation)"

    # 10. Old access token should be revoked after refresh
    get "/api/v1/mcp/status",
      headers: { "Authorization" => "Bearer #{access_token}", "Host" => MCP_HOST }
    assert_response :unauthorized

    # 11. New access token works
    get "/api/v1/mcp/status",
      headers: { "Authorization" => "Bearer #{new_access}", "Host" => MCP_HOST }
    assert_response :ok

    # 12. Revoke
    delete "/api/v1/mcp/token",
      headers: { "Authorization" => "Bearer #{new_access}", "Host" => MCP_HOST }
    assert_response :ok
    assert_response_schema(:simple_message)

    # 13. Revoked token is dead
    get "/api/v1/mcp/status",
      headers: { "Authorization" => "Bearer #{new_access}", "Host" => MCP_HOST }
    assert_response :unauthorized
  end

  test "token exchange with wrong PKCE verifier fails" do
    # Register client
    post "/register",
      params: { client_name: "Bad PKCE", redirect_uris: ["http://localhost:3456/cb"] },
      headers: { "Host" => MCP_HOST },
      as: :json
    assert_response :created
    client_id = json_response["client_id"]

    # Generate PKCE
    code_verifier = SecureRandom.urlsafe_base64(32)
    code_challenge = Base64.urlsafe_encode64(
      Digest::SHA256.digest(code_verifier), padding: false
    )

    # Get auth code
    doorkeeper_h = doorkeeper_headers_for(@admin_user)
    post "/api/v1/mcp/approve_consent",
      params: {
        client_id: client_id,
        redirect_uri: "http://localhost:3456/cb",
        code_challenge: code_challenge,
        code_challenge_method: "S256"
      },
      headers: doorkeeper_h
    assert_response :ok
    auth_code = json_response["code"]

    # Exchange with WRONG verifier
    post "/token",
      params: {
        grant_type: "authorization_code",
        code: auth_code,
        redirect_uri: "http://localhost:3456/cb",
        client_id: client_id,
        code_verifier: "totally-wrong-verifier"
      },
      headers: { "Host" => MCP_HOST },
      as: :json
    assert_response :bad_request
    json = assert_response_schema(:oauth_error_with_description)
    assert_match(/PKCE/, json["error_description"])
  end
end
