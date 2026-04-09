require "test_helper"
require_relative "../mcp_auth_test_helper"

class McpAuthorizeTest < ActionDispatch::IntegrationTest
  include McpAuthTestHelper

  setup do
    @client = McpClient.create!(
      client_name: "AuthZ Test",
      redirect_uris: ["http://localhost:3456/callback", "http://127.0.0.1:8080/cb"]
    )
    @pkce = generate_pkce
  end

  # =========================================================================
  # GET /authorize  (MCP subdomain)
  # =========================================================================

  test "authorize with valid params redirects to consent URL with all OAuth params" do
    get "/authorize",
      params: {
        client_id: @client.client_id,
        redirect_uri: "http://localhost:3456/callback",
        response_type: "code",
        code_challenge: @pkce[:challenge],
        code_challenge_method: "S256",
        state: "xyz-state",
        scope: "mcp:full"
      },
      headers: mcp_host_headers
    assert_response :redirect

    location = response.headers["Location"]
    uri = URI.parse(location)
    assert_equal "/mcp/authorize", uri.path

    # Every OAuth param must be forwarded verbatim
    query = URI.decode_www_form(uri.query).to_h
    assert_equal @client.client_id, query["client_id"]
    assert_equal @client.client_name, query["client_name"]
    assert_equal "http://localhost:3456/callback", query["redirect_uri"]
    assert_equal @pkce[:challenge], query["code_challenge"]
    assert_equal "S256", query["code_challenge_method"]
    assert_equal "xyz-state", query["state"]
    assert_equal "mcp:full", query["scope"]
  end

  test "authorize omits nil optional params from consent redirect" do
    get "/authorize",
      params: {
        client_id: @client.client_id,
        redirect_uri: "http://localhost:3456/callback",
        response_type: "code",
        code_challenge: @pkce[:challenge],
        code_challenge_method: "S256"
        # no state, no scope
      },
      headers: mcp_host_headers
    assert_response :redirect

    query = URI.decode_www_form(URI.parse(response.headers["Location"]).query).to_h
    assert_not query.key?("state"), "nil state should not appear in redirect"
    assert_not query.key?("scope"), "nil scope should not appear in redirect"
  end

  # --- Validation errors render human-readable HTML (browser-facing endpoint) ---

  test "authorize rejects response_type=token (implicit grant)" do
    authorize_with(response_type: "token")
    assert_authorize_error("unsupported_response_type")
  end

  test "authorize rejects missing response_type" do
    authorize_with(response_type: nil)
    assert_authorize_error("unsupported_response_type")
  end

  test "authorize rejects unknown client_id" do
    authorize_with(client_id: "nonexistent-uuid")
    assert_authorize_error("invalid_client")
  end

  test "authorize rejects missing client_id and redirect_uri together" do
    authorize_with(client_id: nil, redirect_uri: nil)
    assert_authorize_error("invalid_request")
  end

  test "authorize rejects redirect_uri not registered for client" do
    authorize_with(redirect_uri: "http://localhost:9999/not-registered")
    assert_authorize_error("invalid_request")
  end

  test "authorize rejects missing PKCE challenge" do
    authorize_with(code_challenge: nil, code_challenge_method: nil)
    assert_authorize_error("invalid_request")
  end

  test "authorize rejects code_challenge_method=plain" do
    authorize_with(code_challenge_method: "plain")
    assert_authorize_error("invalid_request")
  end

  # --- Validation order ---

  test "authorize checks response_type before client_id (so invalid clients don't get probed)" do
    get "/authorize",
      params: {
        client_id: "fake-client",
        redirect_uri: "http://localhost:3456/callback",
        response_type: "token",
        code_challenge: @pkce[:challenge],
        code_challenge_method: "S256"
      },
      headers: mcp_host_headers
    # Should fail on response_type, not on client_id
    assert_authorize_error("unsupported_response_type")
  end

  private

  # DRY helper: sends a valid authorize request with specific overrides
  def authorize_with(**overrides)
    defaults = {
      client_id: @client.client_id,
      redirect_uri: "http://localhost:3456/callback",
      response_type: "code",
      code_challenge: @pkce[:challenge],
      code_challenge_method: "S256"
    }
    get "/authorize", params: defaults.merge(overrides).compact, headers: mcp_host_headers
  end

  def assert_authorize_error(_expected_code = nil)
    assert_response :bad_request
    assert_includes response.content_type, "text/html",
                    "authorize errors should be HTML (browser-facing endpoint)"
    assert_includes response.body, "Authorization failed",
                    "error page should have the standard heading"
  end
end
