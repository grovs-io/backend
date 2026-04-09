require "test_helper"
require_relative "../auth_test_helper"
require_relative "../mcp_auth_test_helper"

class McpAuthTest < ActionDispatch::IntegrationTest
  include AuthTestHelper
  include McpAuthTestHelper

  fixtures :instances, :users, :instance_roles, :projects, :domains,
           :redirect_configs, :links, :applications,
           :ios_configurations, :android_configurations, :web_configurations

  setup do
    @admin_user = users(:admin_user)
    @member_user = users(:member_user)
    @oauth_user = users(:oauth_user)
    @instance = instances(:one)
    @project = projects(:one)
    @project_test = projects(:one_test)
    @domain = domains(:one)
    @admin_headers = create_mcp_headers_for(@admin_user)
    @doorkeeper_headers = doorkeeper_headers_for(@admin_user)
    @test_redirect_uri = "http://localhost:3456/callback"
    @test_client_id = register_mcp_client(redirect_uris: [
      @test_redirect_uri,
      "http://localhost:9876/callback",
      "http://127.0.0.1:8080/callback"
    ])
  end

  # =========================================================================
  # POST /api/v1/mcp/approve_consent  (Doorkeeper-protected)
  # =========================================================================

  test "approve_consent creates authorization code with valid schema" do
    pkce = generate_pkce
    assert_difference "McpAuthorizationCode.count", 1 do
      post "#{MCP_PREFIX}/approve_consent",
        params: {
          redirect_uri: "http://localhost:9876/callback",
          client_id: @test_client_id,
          code_challenge: pkce[:challenge],
          code_challenge_method: "S256",
          state: "my-state",
          scope: "mcp:full"
        },
        headers: @doorkeeper_headers
    end
    assert_response :ok
    json = assert_response_schema(:consent_response)

    assert json["code"].length >= 20, "code should be long enough to be secure"
    assert_equal "http://localhost:9876/callback", json["redirect_uri"]
    assert_equal "my-state", json["state"]
  end

  test "approve_consent stores all PKCE and OAuth fields in the auth code" do
    pkce = generate_pkce
    post "#{MCP_PREFIX}/approve_consent",
      params: {
        redirect_uri: @test_redirect_uri,
        client_id: @test_client_id,
        code_challenge: pkce[:challenge],
        code_challenge_method: "S256",
        state: "state-abc",
        scope: "mcp:full"
      },
      headers: @doorkeeper_headers
    assert_response :ok

    auth_code = McpAuthorizationCode.find_by(code: json_response["code"])
    assert_equal pkce[:challenge], auth_code.code_challenge
    assert_equal "S256", auth_code.code_challenge_method
    assert_equal "state-abc", auth_code.state
    assert_equal "mcp:full", auth_code.scope
    assert_equal @test_client_id, auth_code.client_id
    assert_equal @admin_user.id, auth_code.user_id
  end

  test "approve_consent accepts 127.0.0.1 as localhost" do
    pkce = generate_pkce
    post "#{MCP_PREFIX}/approve_consent",
      params: {
        redirect_uri: "http://127.0.0.1:8080/callback",
        client_id: @test_client_id,
        code_challenge: pkce[:challenge],
        code_challenge_method: "S256"
      },
      headers: @doorkeeper_headers
    assert_response :ok
    assert_response_schema(:consent_response)
  end

  test "approve_consent rejects unregistered redirect_uri" do
    post "#{MCP_PREFIX}/approve_consent",
      params: {
        redirect_uri: "https://evil.com/callback",
        client_id: @test_client_id,
        code_challenge: generate_pkce[:challenge],
        code_challenge_method: "S256"
      },
      headers: @doorkeeper_headers
    assert_response :bad_request
    assert_equal "redirect_uri not registered for this client", json_response["error_description"]
  end

  test "approve_consent rejects https://localhost not in registered URIs" do
    post "#{MCP_PREFIX}/approve_consent",
      params: {
        redirect_uri: "https://localhost:3456/callback",
        client_id: @test_client_id,
        code_challenge: generate_pkce[:challenge],
        code_challenge_method: "S256"
      },
      headers: @doorkeeper_headers
    assert_response :bad_request
    assert_equal "redirect_uri not registered for this client", json_response["error_description"]
  end

  test "approve_consent rejects unregistered client_id" do
    post "#{MCP_PREFIX}/approve_consent",
      params: {
        redirect_uri: @test_redirect_uri,
        client_id: "not-a-registered-client",
        code_challenge: generate_pkce[:challenge],
        code_challenge_method: "S256"
      },
      headers: @doorkeeper_headers
    assert_response :bad_request
    assert_equal "Unknown client_id", json_response["error_description"]
  end

  test "approve_consent rejects redirect_uri not registered for this client" do
    post "#{MCP_PREFIX}/approve_consent",
      params: {
        redirect_uri: "http://localhost:9999/not-registered",
        client_id: @test_client_id,
        code_challenge: generate_pkce[:challenge],
        code_challenge_method: "S256"
      },
      headers: @doorkeeper_headers
    assert_response :bad_request
    assert_equal "redirect_uri not registered for this client", json_response["error_description"]
  end

  test "approve_consent rejects missing PKCE" do
    post "#{MCP_PREFIX}/approve_consent",
      params: {
        redirect_uri: @test_redirect_uri,
        client_id: @test_client_id
      },
      headers: @doorkeeper_headers
    assert_response :bad_request
    assert_equal "PKCE required", json_response["error_description"]
  end

  test "approve_consent rejects code_challenge_method != S256" do
    post "#{MCP_PREFIX}/approve_consent",
      params: {
        redirect_uri: @test_redirect_uri,
        client_id: @test_client_id,
        code_challenge: "some-challenge",
        code_challenge_method: "plain"
      },
      headers: @doorkeeper_headers
    assert_response :bad_request
    assert_equal "PKCE required", json_response["error_description"]
  end

  test "approve_consent requires both redirect_uri and client_id" do
    # Missing redirect_uri
    post "#{MCP_PREFIX}/approve_consent",
      params: { client_id: @test_client_id },
      headers: @doorkeeper_headers
    assert_response :bad_request

    # Missing client_id
    post "#{MCP_PREFIX}/approve_consent",
      params: { redirect_uri: @test_redirect_uri },
      headers: @doorkeeper_headers
    assert_response :bad_request
  end

  test "approve_consent without doorkeeper token returns 401" do
    post "#{MCP_PREFIX}/approve_consent",
      params: {
        redirect_uri: @test_redirect_uri,
        client_id: @test_client_id,
        code_challenge: generate_pkce[:challenge],
        code_challenge_method: "S256"
      },
      headers: { "Host" => "api.example.com" }
    assert_response :unauthorized
  end

  # =========================================================================
  # DELETE /api/v1/mcp/token  (self-revoke, MCP token auth)
  # =========================================================================

  test "revoke_token invalidates the current token" do
    headers = create_mcp_headers_for(@admin_user)

    delete "#{MCP_PREFIX}/token", headers: headers
    assert_response :ok
    assert_response_schema(:simple_message)
    assert_equal "Token revoked", json_response["message"]

    get "#{MCP_PREFIX}/status", headers: headers
    assert_response :unauthorized
  end

  # =========================================================================
  # GET /api/v1/mcp/status  (MCP token auth)
  # =========================================================================

  test "status returns valid schema with full instance data" do
    get "#{MCP_PREFIX}/status", headers: @admin_headers
    assert_response :ok
    json = assert_response_schema(:status_response)

    # User
    assert_equal @admin_user.id, json["user"]["id"]
    assert_equal @admin_user.email, json["user"]["email"]
    assert_equal @admin_user.name, json["user"]["name"]

    # Instances
    assert json["instances"].any?, "admin_user has at least one instance"
    assert_each_item_schema(:instance_status, json["instances"])

    instance_data = json["instances"].find { |i| i["id"] == @instance.hashid }
    assert instance_data.present?

    # Production project
    prod = instance_data["production"]
    assert prod.present?
    assert_response_schema(:project_status, prod)
    assert_equal @project.hashid, prod["id"]
    assert_equal false, prod["test"]

    # Test project
    test_proj = instance_data["test"]
    assert test_proj.present?
    assert_response_schema(:project_status, test_proj)
    assert_equal @project_test.hashid, test_proj["id"]
    assert_equal true, test_proj["test"]
  end

  test "status includes usage block with mau data" do
    get "#{MCP_PREFIX}/status", headers: @admin_headers
    assert_response :ok
    json = json_response

    instance_data = json["instances"].find { |i| i["id"] == @instance.hashid }
    assert instance_data.present?

    usage = instance_data["usage"]
    assert usage.present?, "instance should include usage block"
    assert usage.key?("current_mau"), "usage should include current_mau"
    assert usage.key?("mau_limit"), "usage should include mau_limit"
    assert usage.key?("quota_exceeded"), "usage should include quota_exceeded"
    assert usage.key?("has_subscription"), "usage should include has_subscription"
    assert_kind_of Integer, usage["current_mau"]
    assert_kind_of Integer, usage["mau_limit"]
  end

  # =========================================================================
  # GET /api/v1/mcp/usage  (MCP token auth)
  # =========================================================================

  test "usage returns usage block for a valid instance" do
    get "#{MCP_PREFIX}/usage", params: { instance_id: @instance.hashid }, headers: @admin_headers
    assert_response :ok
    json = json_response

    usage = json["usage"]
    assert usage.present?, "response should include usage block"
    assert usage.key?("current_mau"), "usage should include current_mau"
    assert usage.key?("mau_limit"), "usage should include mau_limit"
    assert usage.key?("quota_exceeded"), "usage should include quota_exceeded"
    assert usage.key?("has_subscription"), "usage should include has_subscription"
    assert_kind_of Integer, usage["current_mau"]
    assert_kind_of Integer, usage["mau_limit"]
  end

  test "usage returns 404 for unknown instance id" do
    get "#{MCP_PREFIX}/usage", params: { instance_id: "nonexistent-hashid" }, headers: @admin_headers
    assert_response :not_found
    assert json_response["error"].present?
  end

  test "usage returns 404 when user does not belong to the instance" do
    # @oauth_user has no instances; @instance belongs to @admin_user
    get "#{MCP_PREFIX}/usage",
      params: { instance_id: @instance.hashid },
      headers: create_mcp_headers_for(@oauth_user)
    assert_response :not_found
  end

  test "usage requires instance_id param" do
    get "#{MCP_PREFIX}/usage", headers: @admin_headers
    assert_response :bad_request
  end

  test "usage without token returns 401" do
    get "#{MCP_PREFIX}/usage",
      params: { instance_id: @instance.hashid },
      headers: { "Host" => MCP_HOST }
    assert_response :unauthorized
  end

  # =========================================================================
  # GET /api/v1/mcp/validate  (MCP token auth — lightweight token check)
  # =========================================================================

  test "validate returns 200 with valid: true for a valid token" do
    get "#{MCP_PREFIX}/validate", headers: @admin_headers
    assert_response :ok
    assert_equal true, json_response["valid"]
  end

  test "validate returns 401 with invalid_token error for a revoked token" do
    token = McpToken.new(user: @admin_user, name: "Revoked For Validate")
    plain = token.generate_token
    token.save!
    token.revoke!

    get "#{MCP_PREFIX}/validate", headers: mcp_headers_with_token(plain)
    assert_response :unauthorized
    www_auth = response.headers["WWW-Authenticate"]
    assert_match(/error="invalid_token"/, www_auth, "revoked token must signal invalid_token per RFC 6750 §3.1")
  end

  test "validate returns 401 without error param when no token is sent" do
    get "#{MCP_PREFIX}/validate", headers: { "Host" => MCP_HOST }
    assert_response :unauthorized
    www_auth = response.headers["WWW-Authenticate"]
    assert_no_match(/error=/, www_auth, "missing-token case must NOT have error= param per RFC 6750 §3")
  end

  test "status scopes instances to the authenticated user" do
    get "#{MCP_PREFIX}/status", headers: create_mcp_headers_for(@oauth_user)
    assert_response :ok
    json = assert_response_schema(:status_response)
    assert_equal [], json["instances"], "user with no instances should get empty array"
  end

  test "status without token returns 401 with WWW-Authenticate pointing to resource metadata" do
    get "#{MCP_PREFIX}/status", headers: { "Host" => MCP_HOST }
    assert_response :unauthorized

    www_auth = response.headers["WWW-Authenticate"]
    assert www_auth.present?, "401 must include WWW-Authenticate header per MCP spec"
    assert www_auth.start_with?("Bearer"), "WWW-Authenticate must use Bearer scheme, got: #{www_auth}"
    assert_match(/resource_metadata=/, www_auth,
                 "must include resource_metadata URL per MCP spec")
    assert_match(%r{\.well-known/oauth-protected-resource}, www_auth,
                 "resource_metadata must point to /.well-known/oauth-protected-resource")
  end

  test "status with revoked token returns 401 with invalid_token error in WWW-Authenticate" do
    token = McpToken.new(user: @admin_user, name: "Revoked")
    plain = token.generate_token
    token.save!
    token.revoke!

    get "#{MCP_PREFIX}/status", headers: mcp_headers_with_token(plain)
    assert_response :unauthorized

    www_auth = response.headers["WWW-Authenticate"]
    assert www_auth.present?, "401 must include WWW-Authenticate header"
    assert_match(/error="invalid_token"/, www_auth,
                 'invalid token must signal error="invalid_token" so OAuth clients refresh (RFC 6750 §3.1)')
    assert_match(/error_description=/, www_auth,
                 "invalid token responses should include error_description")
  end

  test "status with expired token returns 401 with invalid_token error in WWW-Authenticate" do
    token = McpToken.new(user: @admin_user, name: "Expired")
    plain = token.generate_token
    token.expires_at = 1.day.ago
    token.save!

    get "#{MCP_PREFIX}/status", headers: mcp_headers_with_token(plain)
    assert_response :unauthorized

    www_auth = response.headers["WWW-Authenticate"]
    assert_match(/error="invalid_token"/, www_auth,
                 "expired token must signal error=invalid_token to trigger client refresh")
  end

  test "status with malformed bearer token returns 401 with invalid_token error" do
    get "#{MCP_PREFIX}/status",
      headers: { "Authorization" => "Bearer not-a-real-token", "Host" => MCP_HOST }
    assert_response :unauthorized

    www_auth = response.headers["WWW-Authenticate"]
    assert_match(/error="invalid_token"/, www_auth)
  end

  test "status without token returns 401 WITHOUT error= param (RFC 6750 §3)" do
    # Distinguishes "no auth attempted" (no error param) from "auth attempted but failed".
    # OAuth clients use this to decide between "do auth flow" vs "refresh existing token".
    get "#{MCP_PREFIX}/status", headers: { "Host" => MCP_HOST }
    assert_response :unauthorized

    www_auth = response.headers["WWW-Authenticate"]
    assert www_auth.present?
    assert_no_match(/error=/, www_auth,
                    "missing auth must NOT include error= per RFC 6750 §3 — only failed auth attempts get error code")
  end

  # =========================================================================
  # GET /api/v1/mcp/tokens  (Doorkeeper-protected, dashboard)
  # =========================================================================

  test "list_tokens returns valid schema with active tokens" do
    # Create some tokens for the user
    3.times do |i|
      t = McpToken.new(user: @admin_user, name: "Token #{i}")
      t.generate_token
      t.save!
    end
    # Create a revoked token that should NOT appear
    revoked = McpToken.new(user: @admin_user, name: "Revoked")
    revoked.generate_token
    revoked.save!
    revoked.revoke!

    get "#{MCP_PREFIX}/tokens", headers: @doorkeeper_headers
    assert_response :ok
    json = assert_response_schema(:tokens_list)

    tokens = json["tokens"]
    assert tokens.length >= 3, "should include at least the 3 active tokens"
    assert_each_item_schema(:token_list_item, tokens)

    # Revoked token must not appear
    token_names = tokens.map { |t| t["name"] }
    assert_not_includes token_names, "Revoked"
  end

  test "list_tokens only returns current user's tokens" do
    # Token for admin_user
    admin_token = McpToken.new(user: @admin_user, name: "Admin Token")
    admin_token.generate_token
    admin_token.save!

    # Token for member_user
    member_token = McpToken.new(user: @member_user, name: "Member Token")
    member_token.generate_token
    member_token.save!

    get "#{MCP_PREFIX}/tokens", headers: @doorkeeper_headers
    assert_response :ok
    token_names = json_response["tokens"].map { |t| t["name"] }

    assert_includes token_names, "Admin Token"
    assert_not_includes token_names, "Member Token"
  end

  test "list_tokens without doorkeeper auth returns 401" do
    get "#{MCP_PREFIX}/tokens", headers: { "Host" => "api.example.com" }
    assert_response :unauthorized
  end

  test "list_tokens returns tokens ordered by created_at desc" do
    %w[Oldest Middle Newest].each_with_index do |name, i|
      t = McpToken.new(user: @admin_user, name: name)
      t.generate_token
      t.save!
      t.update_column(:created_at, (3 - i).hours.ago)
    end

    get "#{MCP_PREFIX}/tokens", headers: @doorkeeper_headers
    assert_response :ok
    names = json_response["tokens"].map { |t| t["name"] }
    our_names = names.select { |n| %w[Oldest Middle Newest].include?(n) }
    assert_equal %w[Newest Middle Oldest], our_names
  end

  # =========================================================================
  # DELETE /api/v1/mcp/tokens/:id  (Doorkeeper-protected, dashboard)
  # =========================================================================

  test "revoke_token_by_id revokes specific token" do
    token = McpToken.new(user: @admin_user, name: "To Revoke")
    plain = token.generate_token
    token.save!

    delete "#{MCP_PREFIX}/tokens/#{token.hashid}", headers: @doorkeeper_headers
    assert_response :ok
    assert_response_schema(:simple_message)
    assert_equal "Token revoked", json_response["message"]

    # Verify token is actually dead
    get "#{MCP_PREFIX}/status", headers: mcp_headers_with_token(plain)
    assert_response :unauthorized
  end

  test "revoke_token_by_id cannot revoke another user's token" do
    # Create token for member_user
    member_token = McpToken.new(user: @member_user, name: "Member's Token")
    member_token.generate_token
    member_token.save!

    # Try to revoke it as admin_user
    delete "#{MCP_PREFIX}/tokens/#{member_token.hashid}", headers: @doorkeeper_headers
    assert_response :not_found
    assert_response_schema(:simple_error)
  end

  test "revoke_token_by_id with unknown id returns 404" do
    delete "#{MCP_PREFIX}/tokens/nonexistent-hashid", headers: @doorkeeper_headers
    assert_response :not_found
  end

  test "revoke_token_by_id without doorkeeper auth returns 401" do
    token = McpToken.new(user: @admin_user, name: "Whatever")
    token.generate_token
    token.save!

    delete "#{MCP_PREFIX}/tokens/#{token.hashid}", headers: { "Host" => "api.example.com" }
    assert_response :unauthorized
  end

  test "revoke_token_by_id with already-revoked token returns 404" do
    token = McpToken.new(user: @admin_user, name: "Already Revoked")
    token.generate_token
    token.save!
    token.revoke!

    delete "#{MCP_PREFIX}/tokens/#{token.hashid}", headers: @doorkeeper_headers
    assert_response :not_found
  end

  # =========================================================================
  # Behavioral: scope, last_used_at, token lifecycle
  # =========================================================================

  test "scope is preserved from consent through to token response" do
    redirect_uri = "http://localhost:4567/callback"
    client_id = register_mcp_client(redirect_uris: [redirect_uri])
    pkce = generate_pkce

    post "#{MCP_PREFIX}/approve_consent",
      params: {
        redirect_uri: redirect_uri,
        client_id: client_id,
        code_challenge: pkce[:challenge],
        code_challenge_method: "S256",
        scope: "mcp:full"
      },
      headers: @doorkeeper_headers
    assert_response :ok
    code = json_response["code"]

    # Verify scope stored in auth code
    auth_code = McpAuthorizationCode.find_by(code: code)
    assert_equal "mcp:full", auth_code.scope

    # Verify scope returned in token response
    post "/token",
      params: {
        grant_type: "authorization_code",
        code: code,
        redirect_uri: redirect_uri,
        client_id: client_id,
        code_verifier: pkce[:verifier]
      },
      headers: mcp_host_headers,
      as: :json
    assert_response :ok
    assert_equal "mcp:full", json_response["scope"]

    # Verify scope persisted on the token record
    token = McpToken.last
    assert_equal "mcp:full", token.scope
  end

  test "using MCP token updates last_used_at" do
    token = McpToken.new(user: @admin_user, name: "Touch test")
    plain = token.generate_token
    token.save!
    assert_nil token.last_used_at

    get "#{MCP_PREFIX}/status", headers: mcp_headers_with_token(plain)
    assert_response :ok

    token.reload
    assert token.last_used_at.present?, "last_used_at must be updated after API call"
    assert_in_delta Time.current.to_i, token.last_used_at.to_i, 5
  end

  # =========================================================================
  # E2E: consent → exchange → use → revoke lifecycle with schema validation
  # =========================================================================

  test "full auth lifecycle with schema validation at every step" do
    redirect_uri = "http://localhost:4567/callback"
    client_id = register_mcp_client(redirect_uris: [redirect_uri])
    pkce = generate_pkce

    # 1. Consent
    post "#{MCP_PREFIX}/approve_consent",
      params: {
        redirect_uri: redirect_uri,
        client_id: client_id,
        code_challenge: pkce[:challenge],
        code_challenge_method: "S256",
        state: "lifecycle-state"
      },
      headers: @doorkeeper_headers
    assert_response :ok
    consent = assert_response_schema(:consent_response)
    assert_equal "lifecycle-state", consent["state"]

    # 2. Token exchange
    post "/token",
      params: {
        grant_type: "authorization_code",
        code: consent["code"],
        redirect_uri: redirect_uri,
        client_id: client_id,
        code_verifier: pkce[:verifier]
      },
      headers: mcp_host_headers,
      as: :json
    assert_response :ok
    token = assert_response_schema(:token_response)

    # 3. Use token
    get "#{MCP_PREFIX}/status",
      headers: mcp_headers_with_token(token["access_token"])
    assert_response :ok
    assert_response_schema(:status_response)

    # 4. Revoke
    delete "#{MCP_PREFIX}/token",
      headers: mcp_headers_with_token(token["access_token"])
    assert_response :ok
    assert_response_schema(:simple_message)

    # 5. Token is dead
    get "#{MCP_PREFIX}/status",
      headers: mcp_headers_with_token(token["access_token"])
    assert_response :unauthorized
  end
end
