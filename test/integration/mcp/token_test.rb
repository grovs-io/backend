require "test_helper"
require_relative "../auth_test_helper"
require_relative "../mcp_auth_test_helper"

class McpTokenEndpointTest < ActionDispatch::IntegrationTest
  include AuthTestHelper
  include McpAuthTestHelper

  fixtures :instances, :users, :instance_roles, :projects, :domains,
           :redirect_configs, :links, :applications,
           :ios_configurations, :android_configurations, :web_configurations

  setup do
    @user = users(:admin_user)
    @doorkeeper_headers = doorkeeper_headers_for(@user)
    @redirect_uri = "http://localhost:3456/callback"
    @client_id = register_mcp_client(redirect_uris: [@redirect_uri])
  end

  # =========================================================================
  # POST /token  grant_type=authorization_code
  # =========================================================================

  test "authorization_code grant with valid PKCE returns token with schema" do
    pkce = generate_pkce
    code = create_auth_code(pkce: pkce)

    assert_difference "McpToken.count", 1 do
      post "/token",
        params: {
          grant_type: "authorization_code",
          code: code,
          redirect_uri: @redirect_uri,
          client_id: @client_id,
          code_verifier: pkce[:verifier]
        },
        headers: mcp_host_headers,
        as: :json
    end
    assert_response :ok
    json = assert_response_schema(:token_response)

    assert_equal "Bearer", json["token_type"]
    assert_equal McpToken::MCP_TOKEN_TTL.to_i, json["expires_in"]

    # Verify the token actually works
    get "/api/v1/mcp/status",
      headers: mcp_host_headers_with_token(json["access_token"])
    assert_response :ok
  end

  test "authorization_code grant sets token name to client_name" do
    pkce = generate_pkce
    code = create_auth_code(pkce: pkce)

    post "/token",
      params: {
        grant_type: "authorization_code",
        code: code,
        redirect_uri: @redirect_uri,
        client_id: @client_id,
        code_verifier: pkce[:verifier]
      },
      headers: mcp_host_headers,
      as: :json
    assert_response :ok

    token = McpToken.last
    client = McpClient.find_by(client_id: @client_id)
    assert_equal client.client_name, token.name
    assert_equal @client_id, token.client_id
  end

  test "authorization_code grant with wrong PKCE verifier returns 400" do
    pkce = generate_pkce
    code = create_auth_code(pkce: pkce)

    post "/token",
      params: {
        grant_type: "authorization_code",
        code: code,
        redirect_uri: @redirect_uri,
        client_id: @client_id,
        code_verifier: "completely-wrong-verifier"
      },
      headers: mcp_host_headers,
      as: :json
    assert_response :bad_request
    json = assert_response_schema(:oauth_error_with_description)
    assert_match(/PKCE/, json["error_description"])
  end

  test "authorization_code grant with missing code_verifier returns 400" do
    pkce = generate_pkce
    code = create_auth_code(pkce: pkce)

    post "/token",
      params: {
        grant_type: "authorization_code",
        code: code,
        redirect_uri: @redirect_uri,
        client_id: @client_id
        # no code_verifier
      },
      headers: mcp_host_headers,
      as: :json
    assert_response :bad_request
  end

  test "authorization_code grant rejects code without PKCE challenge stored" do
    # Create code without PKCE (bypassing consent, directly via model)
    auth_code = McpAuthorizationCode.generate_for(
      user: @user,
      redirect_uri: @redirect_uri,
      client_id: @client_id
      # no code_challenge
    )

    post "/token",
      params: {
        grant_type: "authorization_code",
        code: auth_code.code,
        redirect_uri: @redirect_uri,
        client_id: @client_id,
        code_verifier: "some-verifier"
      },
      headers: mcp_host_headers,
      as: :json
    assert_response :bad_request
    assert_equal "PKCE required", json_response["error_description"]
  end

  test "authorization_code grant with invalid code returns 400" do
    post "/token",
      params: {
        grant_type: "authorization_code",
        code: "totally-bogus",
        redirect_uri: @redirect_uri,
        client_id: @client_id,
        code_verifier: "anything"
      },
      headers: mcp_host_headers,
      as: :json
    assert_response :bad_request
    json = assert_response_schema(:oauth_error_with_description)
    assert_equal "invalid_grant", json["error"]
  end

  test "authorization_code grant with wrong redirect_uri returns 400" do
    pkce = generate_pkce
    code = create_auth_code(pkce: pkce)

    post "/token",
      params: {
        grant_type: "authorization_code",
        code: code,
        redirect_uri: "http://localhost:9999/wrong",
        client_id: @client_id,
        code_verifier: pkce[:verifier]
      },
      headers: mcp_host_headers,
      as: :json
    assert_response :bad_request
  end

  test "authorization_code grant with wrong client_id returns 400" do
    pkce = generate_pkce
    code = create_auth_code(pkce: pkce)

    other_client_id = register_mcp_client(redirect_uris: ["http://localhost:5555/cb"])

    post "/token",
      params: {
        grant_type: "authorization_code",
        code: code,
        redirect_uri: @redirect_uri,
        client_id: other_client_id,
        code_verifier: pkce[:verifier]
      },
      headers: mcp_host_headers,
      as: :json
    assert_response :bad_request
  end

  test "authorization_code grant code can only be used once" do
    pkce = generate_pkce
    code = create_auth_code(pkce: pkce)
    params = {
      grant_type: "authorization_code",
      code: code,
      redirect_uri: @redirect_uri,
      client_id: @client_id,
      code_verifier: pkce[:verifier]
    }

    post "/token", params: params, headers: mcp_host_headers, as: :json
    assert_response :ok

    post "/token", params: params, headers: mcp_host_headers, as: :json
    assert_response :bad_request
  end

  test "authorization_code grant with expired code returns 400" do
    pkce = generate_pkce
    code = create_auth_code(pkce: pkce)

    travel 2.minutes do
      post "/token",
        params: {
          grant_type: "authorization_code",
          code: code,
          redirect_uri: @redirect_uri,
          client_id: @client_id,
          code_verifier: pkce[:verifier]
        },
        headers: mcp_host_headers,
        as: :json
      assert_response :bad_request
    end
  end

  # =========================================================================
  # POST /token  grant_type=refresh_token
  # =========================================================================

  test "refresh_token grant returns new token pair with schema" do
    tokens = obtain_mcp_token_via_consent(
      user: @user,
      doorkeeper_headers: @doorkeeper_headers
    )

    post "/token",
      params: {
        grant_type: "refresh_token",
        refresh_token: tokens[:refresh_token],
        client_id: tokens[:client_id]
      },
      headers: mcp_host_headers,
      as: :json
    assert_response :ok
    json = assert_response_schema(:token_response)

    assert_not_equal tokens[:access_token], json["access_token"]
    assert_not_equal tokens[:refresh_token], json["refresh_token"]
    assert_equal "Bearer", json["token_type"]
  end

  test "refresh_token grant revokes the old access token" do
    tokens = obtain_mcp_token_via_consent(
      user: @user,
      doorkeeper_headers: @doorkeeper_headers
    )

    # Refresh
    post "/token",
      params: {
        grant_type: "refresh_token",
        refresh_token: tokens[:refresh_token],
        client_id: tokens[:client_id]
      },
      headers: mcp_host_headers,
      as: :json
    assert_response :ok
    new_access = json_response["access_token"]

    # Old token is dead
    get "/api/v1/mcp/status",
      headers: mcp_host_headers_with_token(tokens[:access_token])
    assert_response :unauthorized

    # New token works
    get "/api/v1/mcp/status",
      headers: mcp_host_headers_with_token(new_access)
    assert_response :ok
  end

  test "refresh_token grant with invalid refresh token returns 400" do
    post "/token",
      params: {
        grant_type: "refresh_token",
        refresh_token: "garbage-token",
        client_id: @client_id
      },
      headers: mcp_host_headers,
      as: :json
    assert_response :bad_request
    json = assert_response_schema(:oauth_error_with_description)
    assert_equal "invalid_grant", json["error"]
  end

  test "refresh_token grant with mismatched client_id returns 400" do
    tokens = obtain_mcp_token_via_consent(
      user: @user,
      doorkeeper_headers: @doorkeeper_headers
    )

    other_client_id = register_mcp_client(redirect_uris: ["http://localhost:5555/cb"])

    post "/token",
      params: {
        grant_type: "refresh_token",
        refresh_token: tokens[:refresh_token],
        client_id: other_client_id
      },
      headers: mcp_host_headers,
      as: :json
    assert_response :bad_request
    assert_equal "invalid_grant", json_response["error"]
  end

  test "refresh_token grant with revoked token's refresh returns 400" do
    tokens = obtain_mcp_token_via_consent(
      user: @user,
      doorkeeper_headers: @doorkeeper_headers
    )

    # Revoke the token
    delete "/api/v1/mcp/token",
      headers: mcp_host_headers_with_token(tokens[:access_token])
    assert_response :ok

    # Try to refresh — should fail because token is revoked
    post "/token",
      params: {
        grant_type: "refresh_token",
        refresh_token: tokens[:refresh_token],
        client_id: tokens[:client_id]
      },
      headers: mcp_host_headers,
      as: :json
    assert_response :bad_request
  end

  test "scope is preserved through refresh token rotation" do
    pkce = generate_pkce
    auth_code = McpAuthorizationCode.generate_for(
      user: @user,
      redirect_uri: @redirect_uri,
      client_id: @client_id,
      code_challenge: pkce[:challenge],
      code_challenge_method: "S256",
      scope: "mcp:full"
    )

    post "/token",
      params: {
        grant_type: "authorization_code",
        code: auth_code.code,
        redirect_uri: @redirect_uri,
        client_id: @client_id,
        code_verifier: pkce[:verifier]
      },
      headers: mcp_host_headers,
      as: :json
    assert_response :ok
    first = json_response
    assert_equal "mcp:full", first["scope"]

    post "/token",
      params: {
        grant_type: "refresh_token",
        refresh_token: first["refresh_token"],
        client_id: @client_id
      },
      headers: mcp_host_headers,
      as: :json
    assert_response :ok
    assert_equal "mcp:full", json_response["scope"], "scope must survive refresh rotation"
  end

  test "old refresh token cannot be reused after rotation" do
    tokens = obtain_mcp_token_via_consent(
      user: @user,
      doorkeeper_headers: @doorkeeper_headers
    )

    # First refresh
    post "/token",
      params: {
        grant_type: "refresh_token",
        refresh_token: tokens[:refresh_token],
        client_id: tokens[:client_id]
      },
      headers: mcp_host_headers,
      as: :json
    assert_response :ok

    # Replay old refresh token — must fail
    post "/token",
      params: {
        grant_type: "refresh_token",
        refresh_token: tokens[:refresh_token],
        client_id: tokens[:client_id]
      },
      headers: mcp_host_headers,
      as: :json
    assert_response :bad_request
  end

  test "refresh_token grant succeeds after access token expires" do
    tokens = obtain_mcp_token_via_consent(
      user: @user,
      doorkeeper_headers: @doorkeeper_headers
    )

    # Expire the access token
    digest = Digest::SHA256.hexdigest(tokens[:access_token])
    token_record = McpToken.find_by(token_digest: digest)
    token_record.update_column(:expires_at, 1.hour.ago)

    # Access token is dead
    get "/api/v1/mcp/status",
      headers: mcp_host_headers_with_token(tokens[:access_token])
    assert_response :unauthorized

    # Refresh still works
    post "/token",
      params: {
        grant_type: "refresh_token",
        refresh_token: tokens[:refresh_token],
        client_id: tokens[:client_id]
      },
      headers: mcp_host_headers,
      as: :json
    assert_response :ok
    json = assert_response_schema(:token_response)

    # New access token works
    get "/api/v1/mcp/status",
      headers: mcp_host_headers_with_token(json["access_token"])
    assert_response :ok
  end

  test "refresh_token grant rejected after 90-day TTL expires" do
    tokens = obtain_mcp_token_via_consent(
      user: @user,
      doorkeeper_headers: @doorkeeper_headers
    )

    travel 91.days do
      post "/token",
        params: {
          grant_type: "refresh_token",
          refresh_token: tokens[:refresh_token],
          client_id: tokens[:client_id]
        },
        headers: mcp_host_headers,
        as: :json
      assert_response :bad_request
      assert_equal "invalid_grant", json_response["error"]
    end
  end

  # =========================================================================
  # POST /token  unsupported grant type
  # =========================================================================

  test "rejects unsupported grant types (password, implicit, client_credentials)" do
    %w[password implicit client_credentials].each do |bad_grant|
      post "/token",
        params: { grant_type: bad_grant },
        headers: mcp_host_headers,
        as: :json
      assert_response :bad_request,
                       "grant_type=#{bad_grant} should be rejected"
      assert_equal "unsupported_grant_type", json_response["error"],
                   "grant_type=#{bad_grant} should return unsupported_grant_type error"
    end
  end

  test "missing grant_type returns unsupported_grant_type" do
    post "/token",
      params: { code: "something" },
      headers: mcp_host_headers,
      as: :json
    assert_response :bad_request
    assert_equal "unsupported_grant_type", json_response["error"]
  end

  private

  def create_auth_code(pkce:)
    auth_code = McpAuthorizationCode.generate_for(
      user: @user,
      redirect_uri: @redirect_uri,
      client_id: @client_id,
      code_challenge: pkce[:challenge],
      code_challenge_method: "S256"
    )
    auth_code.code
  end
end
