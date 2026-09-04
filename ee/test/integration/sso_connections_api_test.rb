require "test_helper"
require_relative "../../../test/integration/auth_test_helper"

class SsoConnectionsApiTest < ActionDispatch::IntegrationTest
  include AuthTestHelper
  include AuditTestHelper
  fixtures :instances, :users, :instance_roles

  setup do
    @instance = instances(:one)
    @admin = users(:admin_user)
    @member = users(:member_user)
    entitle!(@instance)
    @env = %w[SERVER_HOST_PROTOCOL SERVER_HOST].index_with { |k| ENV[k] }
    ENV["SERVER_HOST_PROTOCOL"] = "https://"
    ENV["SERVER_HOST"] = "api.example.com"
  end

  teardown do
    @env.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end

  def base = "#{API_PREFIX}/instances/#{@instance.id}/sso_connection"
  def valid_body = { issuer: "https://idp.test/v2.0", client_id: "cid", client_secret: "shh", domains: ["Acme.com"] }

  def stub_issuer_ok(&block)
    SsoConnections::IssuerValidator.stub(:error_for, nil, &block)
  end

  test "GET is null before setup and 403 for members and unentitled instances" do
    get base, headers: doorkeeper_headers_for(@admin)
    assert_response :ok
    assert_nil JSON.parse(response.body)["sso_connection"]
    get base, headers: doorkeeper_headers_for(@member)
    assert_response :forbidden
    unentitle!(@instance)
    get base, headers: doorkeeper_headers_for(@admin)
    assert_response :forbidden
  end

  test "PUT creates, lowercases domains, never returns the secret, and rejects a bad issuer" do
    stub_issuer_ok do
      put base, params: valid_body, headers: doorkeeper_headers_for(@admin), as: :json
    end
    assert_response :ok
    json = JSON.parse(response.body)["sso_connection"]
    assert_equal "acme.com", json["domains"][0]["domain"]
    assert_nil json["domains"][0]["verified_at"]
    assert_equal "_grovs-sso.acme.com", json["domains"][0]["record_name"]
    assert json["client_secret_set"]
    assert_not json.key?("client_secret")
    assert_equal "https://api.example.com/api/v1/identity/sso/auth/oidc/callback", json["redirect_uri"]
    assert_equal "http://api.sqd.link/scim/v2", json["scim"]["base_url"]
    assert_not json["active"]

    SsoConnections::IssuerValidator.stub(:error_for, "discovery failed (DiscoveryFailed)") do
      put base, params: valid_body.merge(issuer: "https://dead.test"), headers: doorkeeper_headers_for(@admin), as: :json
    end
    assert_response :unprocessable_entity
    assert_match(/discovery failed/, JSON.parse(response.body)["error"])
  end

  test "PUT keeps the secret when omitted and reconciles domains" do
    stub_issuer_ok { put base, params: valid_body, headers: doorkeeper_headers_for(@admin), as: :json }
    conn = @instance.reload.sso_connection
    put base, params: { domains: %w[acme.com corp.example] }, headers: doorkeeper_headers_for(@admin), as: :json
    assert_response :ok
    assert_equal "shh", conn.reload.client_secret
    assert_equal %w[acme.com corp.example], conn.domains.order(:domain).pluck(:domain)
  end

  test "enforce needs a verified domain, revokes sessions when flipped on, and blocks DELETE" do
    stub_issuer_ok { put base, params: valid_body, headers: doorkeeper_headers_for(@admin), as: :json }
    put base, params: { enforce: true }, headers: doorkeeper_headers_for(@admin), as: :json
    assert_response :unprocessable_entity

    conn = @instance.reload.sso_connection
    conn.domains.update_all(domain: "example.com", verified_at: Time.current)
    member_headers = doorkeeper_headers_for(@member)
    put base, params: { enforce: true }, headers: doorkeeper_headers_for(@admin), as: :json
    assert_response :ok
    assert_operator JSON.parse(response.body)["sessions_revoked"], :>=, 1
    get "#{API_PREFIX}/users/me", headers: member_headers
    assert_response :unauthorized

    delete base, headers: doorkeeper_headers_for(@admin)
    assert_response :conflict
    put base, params: { enforce: false }, headers: doorkeeper_headers_for(@admin), as: :json
    delete base, headers: doorkeeper_headers_for(@admin)
    assert_response :ok
    assert_nil @instance.reload.sso_connection
  end

  test "verify_domains verifies per domain through an injected resolver and 409s a claimed domain" do
    stub_issuer_ok { put base, params: valid_body.merge(domains: %w[acme.com other.test]), headers: doorkeeper_headers_for(@admin), as: :json }
    conn = @instance.reload.sso_connection
    acme = conn.domains.find_by!(domain: "acme.com")
    resolver = Object.new
    resolver.define_singleton_method(:getresources) do |name, _type|
      name == acme.record_name ? [Resolv::DNS::Resource::IN::TXT.new(acme.record_value)] : []
    end
    SsoConnections::DomainVerifier.stub(:default_resolver, resolver) do
      post "#{base}/verify_domains", headers: doorkeeper_headers_for(@admin)
    end
    assert_response :ok
    domains = JSON.parse(response.body)["sso_connection"]["domains"].index_by { |d| d["domain"] }
    assert domains["acme.com"]["verified_at"]
    assert_nil domains["other.test"]["verified_at"]

    other = SsoConnection.create!(instance: instances(:two), issuer: "https://o.test", client_id: "x", client_secret: "y")
    other.domains.create!(domain: "other.test", verified_at: Time.current)
    resolver2 = Object.new
    resolver2.define_singleton_method(:getresources) do |name, _type|
      row = conn.domains.find_by!(domain: "other.test")
      name == row.record_name ? [Resolv::DNS::Resource::IN::TXT.new(row.record_value)] : []
    end
    SsoConnections::DomainVerifier.stub(:default_resolver, resolver2) do
      post "#{base}/verify_domains", headers: doorkeeper_headers_for(@admin)
    end
    assert_response :conflict
  end

  test "verifying a domain while enforcing signs its users out" do
    stub_issuer_ok { put base, params: valid_body.merge(domains: %w[acme.com example.com]), headers: doorkeeper_headers_for(@admin), as: :json }
    conn = @instance.reload.sso_connection
    conn.domains.find_by!(domain: "acme.com").update!(verified_at: Time.current)
    conn.update!(enforce: true)
    member_headers = doorkeeper_headers_for(@member)
    row = conn.domains.find_by!(domain: "example.com")
    resolver = Object.new
    resolver.define_singleton_method(:getresources) { |name, _t| name == row.record_name ? [Resolv::DNS::Resource::IN::TXT.new(row.record_value)] : [] }
    SsoConnections::DomainVerifier.stub(:default_resolver, resolver) { post "#{base}/verify_domains", headers: doorkeeper_headers_for(@admin) }
    assert_response :ok
    get "#{API_PREFIX}/users/me", headers: member_headers
    assert_response :unauthorized
  end

  test "scim token is shown once, rotates, and can be disabled" do
    stub_issuer_ok { put base, params: valid_body, headers: doorkeeper_headers_for(@admin), as: :json }
    post "#{base}/scim_token", headers: doorkeeper_headers_for(@admin)
    assert_response :created
    first = JSON.parse(response.body)["token"]
    assert first.start_with?("scim_")
    post "#{base}/scim_token", headers: doorkeeper_headers_for(@admin)
    assert_nil SsoConnection.by_scim_token(first)
    delete "#{base}/scim_token", headers: doorkeeper_headers_for(@admin)
    assert_response :ok
    assert_not @instance.reload.sso_connection.scim_enabled
  end
end
