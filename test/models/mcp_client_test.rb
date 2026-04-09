require "test_helper"

class McpClientTest < ActiveSupport::TestCase
  # --- Auto-generated client_id ---

  test "client_id is auto-generated as UUID on create" do
    client = McpClient.create!(
      client_name: "Test Client",
      redirect_uris: ["http://localhost:3000/callback"]
    )
    # UUID v4 format: 8-4-4-4-12 hex
    assert_match(/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i, client.client_id)
  end

  test "client_id is stable after save (not regenerated)" do
    client = McpClient.create!(client_name: "Stable", redirect_uris: ["http://localhost:3000/cb"])
    original_id = client.client_id
    client.update!(client_name: "Renamed")
    assert_equal original_id, client.reload.client_id
  end

  # --- Redirect URI validation (security boundary) ---

  test "accepts http://localhost URIs" do
    client = McpClient.new(
      client_name: "Localhost",
      redirect_uris: ["http://localhost:3000/callback", "http://localhost/cb"]
    )
    assert client.valid?, client.errors.full_messages.join(", ")
  end

  test "accepts http://127.0.0.1 URIs" do
    client = McpClient.new(
      client_name: "Loopback",
      redirect_uris: ["http://127.0.0.1:8080/callback"]
    )
    assert client.valid?, client.errors.full_messages.join(", ")
  end

  test "accepts https non-localhost URIs" do
    client = McpClient.new(
      client_name: "Remote HTTPS",
      redirect_uris: ["https://myapp.example.com/oauth/callback"]
    )
    assert client.valid?, client.errors.full_messages.join(", ")
  end

  test "rejects http non-localhost URIs" do
    client = McpClient.new(
      client_name: "Bad HTTP",
      redirect_uris: ["http://evil.com/callback"]
    )
    assert_not client.valid?
    assert client.errors[:redirect_uris].any?
  end

  test "rejects if any URI in the array is invalid" do
    client = McpClient.new(
      client_name: "Mixed",
      redirect_uris: ["http://localhost:3000/ok", "http://evil.com/bad"]
    )
    assert_not client.valid?
  end

  # --- valid_redirect_uri? (used during consent + authorize) ---

  test "valid_redirect_uri? returns true for registered URI" do
    client = McpClient.create!(
      client_name: "URI Check",
      redirect_uris: ["http://localhost:3000/a", "http://localhost:4000/b"]
    )
    assert client.valid_redirect_uri?("http://localhost:3000/a")
    assert client.valid_redirect_uri?("http://localhost:4000/b")
  end

  test "valid_redirect_uri? returns false for unregistered URI" do
    client = McpClient.create!(
      client_name: "URI Check",
      redirect_uris: ["http://localhost:3000/a"]
    )
    assert_not client.valid_redirect_uri?("http://localhost:9999/other")
    assert_not client.valid_redirect_uri?("")
    assert_not client.valid_redirect_uri?(nil)
  end

  # --- find_by client_id ---

  test "find_by client_id retrieves correct record among many" do
    clients = 3.times.map do |i|
      McpClient.create!(client_name: "Client #{i}", redirect_uris: ["http://localhost:300#{i}/cb"])
    end
    target = clients[1]
    found = McpClient.find_by(client_id: target.client_id)
    assert_equal target.id, found.id
    assert_equal target.client_name, found.client_name
  end
end
