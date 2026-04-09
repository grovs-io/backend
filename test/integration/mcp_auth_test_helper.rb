require_relative "mcp_schema_helper"

module McpAuthTestHelper
  include McpSchemaHelper

  MCP_PREFIX = "/api/v1/mcp".freeze
  MCP_HOST = "mcp.example.com".freeze

  # Create a real MCP token + headers. Call in setup.
  def create_mcp_headers_for(user, token_name: "Test MCP")
    mcp_token = McpToken.new(user: user, name: token_name)
    plain_token = mcp_token.generate_token
    mcp_token.save!

    {
      "Authorization" => "Bearer #{plain_token}",
      "Host" => MCP_HOST
    }
  end

  def json_response
    JSON.parse(response.body)
  end

  def mcp_headers_with_token(plain_token)
    {
      "Authorization" => "Bearer #{plain_token}",
      "Host" => MCP_HOST
    }
  end

  def mcp_host_headers
    { "Host" => MCP_HOST }
  end

  def mcp_host_headers_with_token(plain_token)
    {
      "Authorization" => "Bearer #{plain_token}",
      "Host" => MCP_HOST
    }
  end

  # Registers an McpClient and returns the client_id.
  def register_mcp_client(redirect_uris:, client_name: "test-#{SecureRandom.hex(4)}")
    client = McpClient.create!(
      client_name: client_name,
      redirect_uris: redirect_uris
    )
    client.client_id
  end

  # Returns { verifier:, challenge: } for PKCE S256.
  def generate_pkce
    verifier = SecureRandom.urlsafe_base64(32)
    challenge = Base64.urlsafe_encode64(Digest::SHA256.digest(verifier), padding: false)
    { verifier: verifier, challenge: challenge }
  end

  # Convenience: full consent → token exchange, returns { access_token:, refresh_token:, client_id: }
  def obtain_mcp_token_via_consent(user:, doorkeeper_headers:, redirect_uri: "http://localhost:4567/cb")
    client_id = register_mcp_client(redirect_uris: [redirect_uri])
    pkce = generate_pkce

    post "#{MCP_PREFIX}/approve_consent",
      params: {
        redirect_uri: redirect_uri,
        client_id: client_id,
        code_challenge: pkce[:challenge],
        code_challenge_method: "S256"
      },
      headers: doorkeeper_headers
    code = JSON.parse(response.body)["code"]

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
    token_json = JSON.parse(response.body)

    {
      access_token: token_json["access_token"],
      refresh_token: token_json["refresh_token"],
      client_id: client_id
    }
  end
end
