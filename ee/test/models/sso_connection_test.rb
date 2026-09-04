require "test_helper"

class SsoConnectionTest < ActiveSupport::TestCase
  include AuditTestHelper
  fixtures :instances, :users, :instance_roles

  setup do
    @instance = instances(:one)
    entitle!(@instance)
    @conn = SsoConnection.create!(instance: @instance, issuer: "https://idp.test/v2.0",
                                  client_id: "cid", client_secret: "shh")
  end

  test "rejects a non-https issuer" do
    c = SsoConnection.new(instance: instances(:two), issuer: "http://idp.test", client_id: "a", client_secret: "b")
    assert_not c.valid?
  end

  test "is inactive until a domain is verified, then active" do
    d = @conn.domains.create!(domain: "Acme.COM")
    assert_equal "acme.com", d.domain
    assert_not @conn.active?
    d.update!(verified_at: Time.current)
    assert @conn.reload.active?
    assert @conn.verified_domain?("acme.com")
  end

  test "entitlement gates active?" do
    @conn.domains.create!(domain: "acme.com", verified_at: Time.current)
    unentitle!(@instance)
    assert_not @conn.reload.active?
  end

  test "only one instance can hold a verified domain" do
    @conn.domains.create!(domain: "acme.com", verified_at: Time.current)
    other = SsoConnection.create!(instance: instances(:two), issuer: "https://other.test", client_id: "x", client_secret: "y")
    assert_raises(ActiveRecord::RecordNotUnique) { other.domains.create!(domain: "acme.com", verified_at: Time.current) }
  end

  test "discover finds the connection by email domain, case-insensitively" do
    @conn.domains.create!(domain: "acme.com", verified_at: Time.current)
    assert_equal({ connection_id: @conn.id, enforce: false }, SsoConnection.discover("Bob@ACME.com"))
    assert_equal({ connection_id: nil }, SsoConnection.discover("bob@gmail.com"))
  end

  test "scim token round-trips through the digest and rotation kills the old one" do
    plain = @conn.rotate_scim_token!
    assert plain.start_with?("scim_")
    assert_equal @conn, SsoConnection.by_scim_token(plain)
    @conn.rotate_scim_token!
    assert_nil SsoConnection.by_scim_token(plain)
  end

  test "client secret is encrypted at rest" do
    raw = SsoConnection.connection.select_value("SELECT client_secret FROM sso_connections WHERE id = #{@conn.id}")
    assert_not_equal "shh", raw
    assert_equal "shh", @conn.reload.client_secret
  end

  test "rebindable? treats a dangling or foreign-social provider as unbound" do
    other = SsoConnection.create!(instance: instances(:two), issuer: "https://other.test", client_id: "x", client_secret: "y")
    assert SsoConnection.rebindable?(nil, @conn)
    assert SsoConnection.rebindable?("google_oauth2", @conn)
    assert SsoConnection.rebindable?("oidc:999999", @conn)
    assert SsoConnection.rebindable?(@conn.provider_key, @conn)
    assert_not SsoConnection.rebindable?(other.provider_key, @conn)
  end

  test "reconcile_domains! adds, removes and refuses to strip the last verified domain while enforcing" do
    @conn.domains.create!(domain: "acme.com", verified_at: Time.current)
    @conn.update!(enforce: true)
    @conn.reconcile_domains!(%w[acme.com corp.example])
    assert_equal %w[acme.com corp.example], @conn.domains.order(:domain).pluck(:domain)
    assert_raises(SsoConnection::LastVerifiedDomain) { @conn.reconcile_domains!(%w[corp.example]) }
  end

  test "enable_enforce! revokes domain users' tokens and spares super admins" do
    @conn.domains.create!(domain: "example.com", verified_at: Time.current)
    app = Doorkeeper::Application.create!(name: "t", redirect_uri: "urn:ietf:wg:oauth:2.0:oob")
    member = users(:member_user)
    sa = users(:super_admin_user)
    sa.update!(super_admin: true)
    t1 = Doorkeeper::AccessToken.create!(resource_owner_id: member.id, application_id: app.id, expires_in: 7200)
    t2 = Doorkeeper::AccessToken.create!(resource_owner_id: sa.id, application_id: app.id, expires_in: 7200)
    count = @conn.enable_enforce!
    assert @conn.reload.enforce
    assert_operator count, :>=, 1
    assert_nil Doorkeeper::AccessToken.find_by(id: t1.id)
    assert Doorkeeper::AccessToken.find_by(id: t2.id)
  end

  test "self-hosted domains are verified on create" do
    previous = ENV["GROVS_SELF_HOSTED"]
    ENV["GROVS_SELF_HOSTED"] = "true"
    assert @conn.domains.create!(domain: "onprem.example").verified?
  ensure
    previous.nil? ? ENV.delete("GROVS_SELF_HOSTED") : ENV["GROVS_SELF_HOSTED"] = previous
  end

  test "enable_enforce! refuses an inactive connection" do
    assert_raises(SsoConnection::NotActive) { @conn.enable_enforce! }
  end
end
