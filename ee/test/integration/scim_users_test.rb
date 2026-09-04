require "test_helper"
require_relative "../../../test/integration/auth_test_helper"

class ScimUsersTest < ActionDispatch::IntegrationTest
  include AuthTestHelper
  include AuditTestHelper
  fixtures :instances, :users, :instance_roles

  PATCH_OP = "urn:ietf:params:scim:api:messages:2.0:PatchOp".freeze
  USER_SCHEMA = "urn:ietf:params:scim:schemas:core:2.0:User".freeze

  setup do
    @instance = instances(:one)
    entitle!(@instance)
    @conn = SsoConnection.create!(instance: @instance, issuer: "https://idp.test/v2.0", client_id: "cid", client_secret: "shh")
    @conn.domains.create!(domain: "example.com", verified_at: Time.current)
    @token = @conn.rotate_scim_token!
  end

  def headers(token = @token)
    { "Authorization" => "Bearer #{token}", "Host" => api_host, "Content-Type" => "application/scim+json", "Accept" => "application/scim+json" }
  end

  def user_body(user_name:, email: nil, external_id: "ext-1", display_name: "Alice Adams")
    { schemas: [USER_SCHEMA], userName: user_name, externalId: external_id, displayName: display_name,
      name: { givenName: display_name.split.first, familyName: display_name.split.last },
      emails: [{ type: "work", value: email || user_name, primary: true }], active: true }.to_json
  end

  def json = JSON.parse(response.body)

  test "rejects missing and unknown bearer tokens" do
    get "/scim/v2/Users", headers: { "Host" => api_host }
    assert_response :unauthorized
    get "/scim/v2/Users", headers: headers("scim_nope")
    assert_response :unauthorized
    assert_equal ["urn:ietf:params:scim:api:messages:2.0:Error"], json["schemas"]
  end

  test "serves ServiceProviderConfig and stamps the last use" do
    assert_nil @conn.scim_last_used_at
    get "/scim/v2/ServiceProviderConfig", headers: headers
    assert_response :ok
    assert json["patch"]["supported"]
    assert @conn.reload.scim_last_used_at
  end

  test "creates a passwordless member and lowercases the UPN" do
    post "/scim/v2/Users", params: user_body(user_name: "Alice@Example.com", email: "alice.adams@example.com"), headers: headers
    assert_response :created
    assert_equal "alice@example.com", json["userName"]
    assert_equal "ext-1", json["externalId"]
    assert_equal true, json["active"]
    user = User.find_for_email("alice.adams@example.com")
    assert_equal @conn.provider_key, user.provider
    assert_nil user.uid
    assert user.encrypted_password.blank?
    assert_equal "member", InstanceRole.find_by(user: user, instance: @instance).role
    assert_equal user.id, json["id"].to_i
  end

  test "create without active still yields a member" do
    body = JSON.parse(user_body(user_name: "eve@example.com")).except("active").to_json
    post "/scim/v2/Users", params: body, headers: headers
    assert_response :created
    assert_equal true, json["active"]
    assert InstanceRole.exists?(user: User.find_for_email("eve@example.com"), instance: @instance)
  end

  test "create with active false binds the user without a role" do
    body = JSON.parse(user_body(user_name: "staged@example.com")).merge("active" => false).to_json
    post "/scim/v2/Users", params: body, headers: headers
    assert_response :created
    assert_equal false, json["active"]
    assert_nil InstanceRole.find_by(user: User.find_for_email("staged@example.com"), instance: @instance)
  end

  test "create falls back to the UPN when no email is sent" do
    body = JSON.parse(user_body(user_name: "nomail@example.com")).except("emails").to_json
    post "/scim/v2/Users", params: body, headers: headers
    assert_response :created
    assert User.find_for_email("nomail@example.com")
  end

  test "adopting an existing user on a foreign domain or an operator account is refused" do
    User.create!(email: "victim@other.test", name: "V", password: "Password123!")
    post "/scim/v2/Users", params: user_body(user_name: "attacker@example.com", email: "victim@other.test"), headers: headers
    assert_response :bad_request
    assert_nil User.find_for_email("victim@other.test").scim_user_name
    users(:super_admin_user).update!(super_admin: true, email: "root@example.com")
    post "/scim/v2/Users", params: user_body(user_name: "root@example.com"), headers: headers
    assert_response :forbidden
  end

  test "a token stops working when the connection is no longer active" do
    unentitle!(@instance)
    get "/scim/v2/Users", headers: headers
    assert_response :unauthorized
  end

  test "binds an existing invited user, consuming the invitation" do
    invitee = User.invite!({ email: "bob@example.com", skip_invitation: true }, users(:admin_user))
    post "/scim/v2/Users", params: user_body(user_name: "bob@example.com", external_id: "ext-bob"), headers: headers
    assert_response :created
    invitee.reload
    assert_equal @conn.provider_key, invitee.provider
    assert_equal "ext-bob", invitee.scim_external_id
    assert_nil invitee.invitation_token
  end

  test "a pre-existing dashboard member is adopted, not refused" do
    post "/scim/v2/Users", params: user_body(user_name: "member.upn@example.com", email: "member@example.com"), headers: headers
    assert_response :created
    member = users(:member_user).reload
    assert_equal @conn.provider_key, member.provider
    assert_equal "member.upn@example.com", member.scim_user_name
    assert_equal "member", InstanceRole.find_by(user: member, instance: @instance).role
  end

  test "duplicate create is 409 uniqueness and a foreign email domain is 400" do
    post "/scim/v2/Users", params: user_body(user_name: "alice@example.com"), headers: headers
    assert_response :created
    post "/scim/v2/Users", params: user_body(user_name: "alice@example.com"), headers: headers
    assert_response :conflict
    assert_equal "uniqueness", json["scimType"]
    post "/scim/v2/Users", params: user_body(user_name: "x@example.com", email: "x@gmail.com"), headers: headers
    assert_response :bad_request
    assert_equal "invalidValue", json["scimType"]
  end

  test "a user bound to another live connection is 409, a dangling key rebinds" do
    other = SsoConnection.create!(instance: instances(:two), issuer: "https://o.test", client_id: "x", client_secret: "y")
    User.create!(email: "dave@example.com", name: "Dave", provider: other.provider_key, uid: "d")
    post "/scim/v2/Users", params: user_body(user_name: "dave@example.com"), headers: headers
    assert_response :conflict
    other.destroy!
    post "/scim/v2/Users", params: user_body(user_name: "dave@example.com"), headers: headers
    assert_response :created
  end

  test "filters by userName (case-insensitive) and externalId (exact), rejects unknown filters, isolates instances" do
    post "/scim/v2/Users", params: user_body(user_name: "alice@example.com", external_id: "EXT-A"), headers: headers
    get "/scim/v2/Users", params: { filter: 'userName eq "ALICE@example.com"' }, headers: headers
    assert_response :ok
    assert_equal 1, json["totalResults"]
    get "/scim/v2/Users", params: { filter: 'externalId eq "EXT-A"' }, headers: headers
    assert_equal 1, json["totalResults"]
    get "/scim/v2/Users", params: { filter: 'nickName eq "x"' }, headers: headers
    assert_response :bad_request

    outsider = users(:super_admin_user)
    get "/scim/v2/Users/#{outsider.id}", headers: headers
    assert_response :not_found
    get "/scim/v2/Users", headers: headers
    assert_not_includes json["Resources"].map { |r| r["id"].to_i }, outsider.id
  end

  test "a member bound to another live connection is invisible to this token" do
    other = SsoConnection.create!(instance: instances(:two), issuer: "https://o.test", client_id: "x", client_secret: "y")
    member = users(:member_user)
    member.update!(provider: other.provider_key, uid: "m")
    get "/scim/v2/Users/#{member.id}", headers: headers
    assert_response :not_found
    get "/scim/v2/Users", headers: headers
    assert_not_includes json["Resources"].map { |r| r["id"].to_i }, member.id
    other.destroy!
    get "/scim/v2/Users/#{member.id}", headers: headers
    assert_response :ok
  end

  test "externalId still resolves after the user logged in through OIDC" do
    post "/scim/v2/Users", params: user_body(user_name: "alice@example.com", external_id: "ext-a"), headers: headers
    User.find_for_email("alice@example.com").update!(uid: "pairwise-sub")
    get "/scim/v2/Users", params: { filter: 'externalId eq "ext-a"' }, headers: headers
    assert_equal 1, json["totalResults"]
  end

  test "Entra-style deactivate removes the role and every session; reactivate restores member" do
    member = users(:member_user)
    member.update!(provider: @conn.provider_key, scim_user_name: "member@example.com")
    dash = doorkeeper_headers_for(member)
    body = { schemas: [PATCH_OP], Operations: [{ op: "Replace", value: { active: "False" } }] }.to_json
    patch "/scim/v2/Users/#{member.id}", params: body, headers: headers
    assert_response :ok
    assert_equal false, json["active"]
    assert_nil InstanceRole.find_by(user: member, instance: @instance)
    get "#{API_PREFIX}/users/me", headers: dash
    assert_response :unauthorized

    body = { schemas: [PATCH_OP], Operations: [{ op: "replace", path: "active", value: true }] }.to_json
    patch "/scim/v2/Users/#{member.id}", params: body, headers: headers
    assert_response :ok
    assert_equal "member", InstanceRole.find_by(user: member, instance: @instance).role
    assert_equal %w[scim.user.deactivated scim.user.reactivated],
                 AuditEvent.where(instance_id: @instance.id).where("action LIKE 'scim.%'").order(:sequence).pluck(:action)
  end

  test "the last admin cannot be deactivated and neither can a super admin" do
    admin = users(:admin_user)
    admin.update!(provider: @conn.provider_key)
    body = { schemas: [PATCH_OP], Operations: [{ op: "replace", path: "active", value: false }] }.to_json
    patch "/scim/v2/Users/#{admin.id}", params: body, headers: headers
    assert_response :conflict
    assert_match(/last admin/, json["detail"])

    root = users(:super_admin_user)
    root.update!(super_admin: true, provider: @conn.provider_key)
    InstanceRole.create!(instance: @instance, user: root, role: "member")
    patch "/scim/v2/Users/#{root.id}", params: body, headers: headers
    assert_response :forbidden
  end

  test "PUT renames UPN and email within verified domains, refuses foreign or taken addresses" do
    post "/scim/v2/Users", params: user_body(user_name: "alice@example.com"), headers: headers
    id = json["id"]
    put "/scim/v2/Users/#{id}", params: user_body(user_name: "alice.new@example.com", email: "alice.new@example.com"), headers: headers
    assert_response :ok
    assert_equal "alice.new@example.com", User.find(id).email
    put "/scim/v2/Users/#{id}", params: user_body(user_name: "alice.new@example.com", email: "alice@gmail.com"), headers: headers
    assert_response :bad_request
    put "/scim/v2/Users/#{id}", params: user_body(user_name: "alice.new@example.com", email: "member@example.com"), headers: headers
    assert_response :conflict
  end

  test "DELETE deactivates and keeps the row bound" do
    post "/scim/v2/Users", params: user_body(user_name: "alice@example.com"), headers: headers
    id = json["id"]
    delete "/scim/v2/Users/#{id}", headers: headers
    assert_response :no_content
    user = User.find(id)
    assert_equal @conn.provider_key, user.provider
    assert_nil InstanceRole.find_by(user: user, instance: @instance)
  end
end
