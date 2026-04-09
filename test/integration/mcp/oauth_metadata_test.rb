require "test_helper"
require_relative "../mcp_auth_test_helper"

class McpOauthMetadataTest < ActionDispatch::IntegrationTest
  include McpAuthTestHelper

  # =========================================================================
  # GET /.well-known/oauth-protected-resource
  # =========================================================================

  test "protected_resource returns valid schema" do
    get "/.well-known/oauth-protected-resource", headers: mcp_host_headers
    assert_response :ok
    json = assert_response_schema(:protected_resource_metadata)

    assert_includes json["resource"], "mcp"
    assert json["authorization_servers"].length >= 1
    assert_includes json["scopes_supported"], "mcp:full"
  end

  test "protected_resource authorization_servers points to self" do
    get "/.well-known/oauth-protected-resource", headers: mcp_host_headers
    json = json_response

    # The auth server should be the same host
    assert_equal json["resource"], json["authorization_servers"].first
  end

  # =========================================================================
  # GET /.well-known/oauth-authorization-server
  # =========================================================================

  test "authorization_server returns valid schema" do
    get "/.well-known/oauth-authorization-server", headers: mcp_host_headers
    assert_response :ok
    json = assert_response_schema(:authorization_server_metadata)

    # Verify required OAuth 2.1 fields have correct values
    assert json["issuer"].present?
    assert json["authorization_endpoint"].end_with?("/authorize")
    assert json["token_endpoint"].end_with?("/token")
    assert json["registration_endpoint"].end_with?("/register")
  end

  test "authorization_server advertises S256 PKCE" do
    get "/.well-known/oauth-authorization-server", headers: mcp_host_headers
    json = json_response

    assert_includes json["code_challenge_methods_supported"], "S256"
    # Must NOT advertise plain (security risk)
    assert_not_includes json["code_challenge_methods_supported"], "plain"
  end

  test "authorization_server advertises correct grant types" do
    get "/.well-known/oauth-authorization-server", headers: mcp_host_headers
    json = json_response

    assert_includes json["grant_types_supported"], "authorization_code"
    assert_includes json["grant_types_supported"], "refresh_token"
    # Must NOT advertise implicit or password grants
    assert_not_includes json["grant_types_supported"], "implicit"
    assert_not_includes json["grant_types_supported"], "password"
  end

  test "authorization_server advertises none for token_endpoint_auth" do
    get "/.well-known/oauth-authorization-server", headers: mcp_host_headers
    json = json_response

    # Public clients (MCP) use "none" — no client_secret
    assert_includes json["token_endpoint_auth_methods_supported"], "none"
  end

  test "authorization_server response_types is code only" do
    get "/.well-known/oauth-authorization-server", headers: mcp_host_headers
    json = json_response

    assert_equal ["code"], json["response_types_supported"]
  end

  test "authorization_server endpoints use consistent base URL" do
    get "/.well-known/oauth-authorization-server", headers: mcp_host_headers
    json = json_response

    issuer = json["issuer"]
    assert json["authorization_endpoint"].start_with?(issuer)
    assert json["token_endpoint"].start_with?(issuer)
    assert json["registration_endpoint"].start_with?(issuer)
  end
end
