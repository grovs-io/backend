require "test_helper"
require_relative "../../../test/integration/auth_test_helper"

class OidcLoginTest < ActionDispatch::IntegrationTest
  include AuthTestHelper
  include AuditTestHelper
  fixtures :instances, :users, :instance_roles

  ENV_KEYS = %w[REACT_HOST_PROTOCOL REACT_HOST SERVER_HOST_PROTOCOL SERVER_HOST SSO_AUTHENTICATION_ENDPOINT].freeze

  setup do
    @env = ENV_KEYS.index_with { |k| ENV[k] }
    ENV["REACT_HOST_PROTOCOL"] = "https://"
    ENV["REACT_HOST"] = "app.example.com"
    ENV["SERVER_HOST_PROTOCOL"] = "https://"
    ENV["SERVER_HOST"] = "api.example.com"
    ENV["SSO_AUTHENTICATION_ENDPOINT"] = "https://app.example.com/login"
    Doorkeeper::Application.create!(name: "React", redirect_uri: "urn:ietf:wg:oauth:2.0:oob")
    host! api_host
    @instance = instances(:one)
    entitle!(@instance)
    @conn = SsoConnection.create!(instance: @instance, issuer: OidcTestIdp::ISSUER, client_id: OidcTestIdp::CLIENT_ID,
                                  client_secret: "shh", admin_claim_value: "grovs-admin")
    @conn.domains.create!(domain: "example.com", verified_at: Time.current)
    OidcTestIdp.enable!
  end

  teardown do
    OidcTestIdp.disable!
    @env.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end

  def start!(conn = @conn)
    get "/api/v1/identity/sso/auth/oidc", params: { c: conn.id }
    assert_response :redirect
    q = Rack::Utils.parse_query(URI(response.location).query)
    [q["state"], q["nonce"]]
  end

  def finish!(state, id_token)
    OidcTestIdp.stub_token!(id_token)
    get "/api/v1/identity/sso/auth/oidc/callback", params: { code: "abc", state: state }
    assert_response :redirect
    response.location
  end

  def login!(**claims)
    state, nonce = start!
    finish!(state, OidcTestIdp.mint(nonce: nonce, **claims))
  end

  def assert_dashboard_error(location, pattern)
    assert location.start_with?("https://app.example.com?error="), location
    assert_match(pattern, CGI.unescape(location))
  end

  test "discover answers by verified domain only for active connections" do
    post "/api/v1/identity/sso/discover", params: { email: "Bob@Example.com" }
    assert_equal({ "connection_id" => @conn.id, "enforce" => false }, JSON.parse(response.body))
    post "/api/v1/identity/sso/discover", params: { email: "bob@gmail.com" }
    assert_equal({ "connection_id" => nil }, JSON.parse(response.body))
  end

  test "passthru returns the request-phase URL and 404s an inactive connection" do
    post "/api/v1/identity/sso/auth/oidc", params: { connection_id: @conn.id }
    assert_response :ok
    assert_equal "https://api.example.com/api/v1/identity/sso/auth/oidc?c=#{@conn.id}", JSON.parse(response.body)["redirect_url"]
    post "/api/v1/identity/sso/auth/oidc", params: { connection_id: @conn.id, email: "Alice@Example.com" }
    assert_equal "https://api.example.com/api/v1/identity/sso/auth/oidc?c=#{@conn.id}&login_hint=alice%40example.com",
                 JSON.parse(response.body)["redirect_url"]
    @conn.domains.update_all(verified_at: nil)
    post "/api/v1/identity/sso/auth/oidc", params: { connection_id: @conn.id }
    assert_response :not_found
  end

  test "request phase redirects to the IdP with state, nonce, PKCE and the login hint" do
    get "/api/v1/identity/sso/auth/oidc", params: { c: @conn.id, login_hint: "alice@example.com" }
    assert_response :redirect
    assert response.location.start_with?("https://idp.test/authorize?")
    q = Rack::Utils.parse_query(URI(response.location).query)
    assert_equal "alice@example.com", q["login_hint"]
    assert q["state"].present? && q["nonce"].present? && q["code_challenge"].present?
    assert_equal "S256", q["code_challenge_method"]
    assert_equal "query", q["response_mode"]
    assert SsoAuthenticationService.valid_state?(state: q["state"])
  end

  test "request phase for an inactive connection lands on the dashboard error page, never 500" do
    @conn.domains.update_all(verified_at: nil)
    get "/api/v1/identity/sso/auth/oidc", params: { c: @conn.id }
    assert_response :redirect
    assert_dashboard_error(response.location, /not available/)
  end

  test "first login provisions a member and returns a dashboard token" do
    location = login!(email: "alice@example.com")
    assert location.start_with?("https://app.example.com?token="), location
    user = User.find_for_email("alice@example.com")
    assert_equal @conn.provider_key, user.provider
    assert_equal "sub-1", user.uid
    assert_equal "member", InstanceRole.find_by(user: user, instance: @instance).role
  end

  test "roles claim grants admin and never downgrades" do
    login!(email: "root@example.com", roles: ["grovs-admin"])
    user = User.find_for_email("root@example.com")
    assert_equal "admin", InstanceRole.find_by(user: user, instance: @instance).role
    login!(email: "root@example.com", roles: [])
    assert_equal "admin", InstanceRole.find_by(user: user, instance: @instance).reload.role
  end

  test "an existing password user binds by email and a pending invite is consumed" do
    invitee = User.invite!({ email: "bob@example.com", skip_invitation: true }, users(:admin_user))
    login!(email: "bob@example.com", sub: "sub-bob")
    invitee.reload
    assert_equal "sub-bob", invitee.uid
    assert_nil invitee.invitation_token
    assert invitee.invitation_accepted_at
  end

  test "a SCIM-provisioned user without an email claim resolves by UPN with no duplicate" do
    User.create!(email: "carol.mail@example.com", name: "Carol", provider: @conn.provider_key, scim_user_name: "carol@example.com")
    login!(email: nil, preferred_username: "Carol@Example.com", sub: "sub-carol")
    assert_equal 1, User.where("email LIKE ?", "%carol%").count
    assert_equal "sub-carol", User.find_for_email("carol.mail@example.com").uid
  end

  test "groups claim also grants admin" do
    login!(email: "grp@example.com", groups: ["grovs-admin"])
    assert_equal "admin", InstanceRole.find_by(user: User.find_for_email("grp@example.com"), instance: @instance).role
  end

  test "a SCIM identity whose email domain is no longer verified is refused, and so are operators" do
    User.create!(email: "moved@other.test", name: "M", provider: @conn.provider_key, scim_user_name: "moved@example.com")
    assert_dashboard_error(login!(email: nil, preferred_username: "moved@example.com", sub: "s-m"), /not enabled/)
    users(:super_admin_user).update!(super_admin: true, email: "root@example.com")
    assert_dashboard_error(login!(email: "root@example.com"), /Operator/)
  end

  test "a UPN on a foreign domain with no SCIM row is refused" do
    location = login!(email: nil, preferred_username: "guest@gmail.com")
    assert_dashboard_error(location, /not enabled/)
  end

  test "guest email outside the verified domains is refused" do
    assert_dashboard_error(login!(email: "alice@gmail.com"), /not enabled/)
  end

  test "a user bound to another instance's live connection is refused, a dangling key rebinds" do
    other = SsoConnection.create!(instance: instances(:two), issuer: "https://o.test", client_id: "x", client_secret: "y")
    User.create!(email: "dave@example.com", name: "Dave", provider: other.provider_key, uid: "d", scim_user_name: "dave@example.com")
    assert_dashboard_error(login!(email: "dave@example.com", sub: "sub-dave"), /another organisation/)
    other.destroy!
    @conn.update!(scim_enabled: true)
    login!(email: "dave@example.com", sub: "sub-dave")
    dave = User.find_for_email("dave@example.com")
    assert_equal @conn.provider_key, dave.provider
    assert_nil dave.scim_user_name
    assert_equal "member", InstanceRole.find_by(user: dave, instance: @instance).role
  end

  test "a user deactivated over SCIM is refused at the IdP until reactivated or SCIM is turned off" do
    @conn.update!(scim_enabled: true)
    bob = User.create!(email: "bob@example.com", name: "Bob", provider: @conn.provider_key, uid: "sub-bob", scim_user_name: "bob@example.com")
    assert_dashboard_error(login!(email: "bob@example.com", sub: "sub-bob"), /deactivated by your organisation/)
    assert_nil InstanceRole.find_by(user: bob, instance: @instance)

    InstanceRole.create!(user: bob, instance: @instance, role: "member")
    login!(email: "bob@example.com", sub: "sub-bob")
    assert_equal "member", InstanceRole.find_by(user: bob, instance: @instance).role

    InstanceRole.where(user: bob).delete_all
    @conn.update!(scim_enabled: false)
    login!(email: "bob@example.com", sub: "sub-bob")
    assert_equal "member", InstanceRole.find_by(user: bob, instance: @instance).role
  end

  test "jit off refuses unknown users" do
    @conn.update!(jit_provision: false)
    assert_dashboard_error(login!(email: "nobody@example.com"), /No account/)
  end

  test "invalid tokens land on the dashboard error page, never 500" do
    state, nonce = start!
    assert_dashboard_error(finish!(state, OidcTestIdp.mint(nonce: "wrong")), /rejected/)
    state, nonce = start!
    assert_dashboard_error(finish!(state, OidcTestIdp.mint(nonce: nonce, iss: "https://evil.test")), /rejected/)
    state, nonce = start!
    assert_dashboard_error(finish!(state, OidcTestIdp.mint(nonce: nonce, aud: "other")), /rejected/)
    state, nonce = start!
    assert_dashboard_error(finish!(state, OidcTestIdp.mint(nonce: nonce, exp: Time.now.to_i - 10)), /rejected/)
    state, nonce = start!
    rogue = JSON::JWK.new(OpenSSL::PKey::RSA.new(2048), kid: "k1")
    assert_dashboard_error(finish!(state, OidcTestIdp.mint(nonce: nonce, key: rogue)), /rejected/)
    state, nonce = start!
    assert_dashboard_error(finish!(state, OidcTestIdp.mint(nonce: nonce, key: "shh", alg: :HS256)), /rejected/)
  end

  test "a database error on the callback becomes a generic message, not the SQL" do
    state, nonce = start!
    boom = ActiveRecord::RecordNotUnique.new("PG::UniqueViolation: duplicate key ... INSERT INTO users")
    SsoEnforcement.stub(:enterprise_login, ->(**) { raise boom }) do
      location = finish!(state, OidcTestIdp.mint(nonce: nonce))
      assert_dashboard_error(location, /Sign-in failed/)
      assert_no_match(/INSERT/, CGI.unescape(location))
    end
  end

  test "an exception during setup reads as a generic failure, not an IdP rejection" do
    SsoConnection.stub(:find_by, ->(*) { raise ActiveRecord::StatementInvalid, "PG::ConnectionBad" }) do
      get "/api/v1/identity/sso/auth/oidc", params: { c: @conn.id }
    end
    assert_dashboard_error(response.location, /Sign-in failed/)
  end

  test "losing a JIT race binds the winner's row instead of failing" do
    original = User.method(:create!)
    calls = 0
    racing = lambda do |**attrs|
      user = original.call(**attrs)
      raise ActiveRecord::RecordNotUnique, "duplicate key" if (calls += 1) == 1

      user
    end
    User.stub(:create!, racing) do
      location = login!(email: "race@example.com", sub: "sub-race")
      assert location.start_with?("https://app.example.com?token="), location
    end
    assert_equal "sub-race", User.find_for_email("race@example.com").uid
    assert_equal 1, User.where(email: "race@example.com").count
  end

  test "a tampered state reads as a rejected sign-in" do
    state, nonce = start!
    OidcTestIdp.stub_token!(OidcTestIdp.mint(nonce: nonce))
    get "/api/v1/identity/sso/auth/oidc/callback", params: { code: "abc", state: "#{state}x" }
    assert_dashboard_error(response.location, /rejected/)
  end

  test "a rotated JWKS is accepted on the next login" do
    new_key = JSON::JWK.new(OpenSSL::PKey::RSA.new(2048), kid: "k2")
    OidcTestIdp.stub_jwks!(new_key)
    location = login!(email: "alice@example.com", key: new_key)
    assert location.start_with?("https://app.example.com?token="), location
  end

  test "OTP is not consulted" do
    users(:member_user).update!(otp_required_for_login: true, otp_secret: User.generate_otp_secret)
    location = login!(email: "member@example.com")
    assert location.start_with?("https://app.example.com?token="), location
  end
end
