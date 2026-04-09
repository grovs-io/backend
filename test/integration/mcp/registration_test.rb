require "test_helper"
require_relative "../mcp_auth_test_helper"

class McpRegistrationTest < ActionDispatch::IntegrationTest
  include McpAuthTestHelper

  # =========================================================================
  # POST /register  (RFC 7591 dynamic client registration)
  # =========================================================================

  test "register with valid params returns client with schema" do
    post "/register",
      params: {
        client_name: "Claude Desktop",
        redirect_uris: ["http://localhost:3456/callback"]
      },
      headers: mcp_host_headers,
      as: :json
    assert_response :created
    json = assert_response_schema(:client_registration)

    assert json["client_id"].present?
    assert_equal "Claude Desktop", json["client_name"]
    assert_equal ["http://localhost:3456/callback"], json["redirect_uris"]
    assert_includes json["grant_types"], "authorization_code"
    assert_includes json["response_types"], "code"
    assert_equal "none", json["token_endpoint_auth_method"]
    assert_equal "native", json["application_type"]
  end

  test "register preserves all redirect_uris in response" do
    uris = ["http://localhost:3000/a", "http://127.0.0.1:4000/b"]
    post "/register",
      params: { client_name: "Multi-URI", redirect_uris: uris },
      headers: mcp_host_headers,
      as: :json
    assert_response :created
    json = assert_response_schema(:client_registration)

    assert_equal uris.sort, json["redirect_uris"].sort
  end

  test "register deduplicates by client_name + redirect_uris" do
    params = { client_name: "DedupTest", redirect_uris: ["http://localhost:3000/cb"] }

    post "/register", params: params, headers: mcp_host_headers, as: :json
    assert_response :created
    first_id = json_response["client_id"]

    post "/register", params: params, headers: mcp_host_headers, as: :json
    assert_response :created
    second_id = json_response["client_id"]

    assert_equal first_id, second_id, "same name + URIs should return existing client"
  end

  test "register creates new client when same name but different URIs" do
    post "/register",
      params: { client_name: "SameName", redirect_uris: ["http://localhost:3000/a"] },
      headers: mcp_host_headers,
      as: :json
    first_id = json_response["client_id"]

    post "/register",
      params: { client_name: "SameName", redirect_uris: ["http://localhost:4000/b"] },
      headers: mcp_host_headers,
      as: :json
    second_id = json_response["client_id"]

    assert_not_equal first_id, second_id
  end

  test "register uses custom grant_types and response_types when provided" do
    post "/register",
      params: {
        client_name: "Custom",
        redirect_uris: ["http://localhost:3000/cb"],
        grant_types: ["authorization_code", "refresh_token"],
        response_types: ["code"],
        application_type: "web"
      },
      headers: mcp_host_headers,
      as: :json
    assert_response :created
    json = assert_response_schema(:client_registration)

    assert_includes json["grant_types"], "refresh_token"
    assert_equal "web", json["application_type"]
  end

  # --- Error cases ---

  test "register requires both client_name and redirect_uris" do
    # Missing client_name
    post "/register",
      params: { redirect_uris: ["http://localhost:3000/cb"] },
      headers: mcp_host_headers, as: :json
    assert_response :bad_request

    # Missing redirect_uris
    post "/register",
      params: { client_name: "No URIs" },
      headers: mcp_host_headers, as: :json
    assert_response :bad_request

    # Both missing
    post "/register",
      params: {},
      headers: mcp_host_headers, as: :json
    assert_response :bad_request
  end

  test "register rejects non-localhost HTTP redirect_uris" do
    post "/register",
      params: {
        client_name: "Bad URI",
        redirect_uris: ["http://evil.com/steal"]
      },
      headers: mcp_host_headers,
      as: :json
    assert_response :bad_request
    assert_match(/redirect/i, response.body, "error should mention redirect URIs")
  end
end
