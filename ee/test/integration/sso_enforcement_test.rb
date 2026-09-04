require "test_helper"
require "rake"
require_relative "../../../test/integration/auth_test_helper"

class SsoEnforcementTest < ActionDispatch::IntegrationTest
  include AuthTestHelper
  include AuditTestHelper
  fixtures :instances, :users, :instance_roles

  setup do
    @instance = instances(:one)
    entitle!(@instance)
    @conn = SsoConnection.create!(instance: @instance, issuer: "https://idp.test/v2.0", client_id: "cid", client_secret: "shh")
    @conn.domains.create!(domain: "example.com", verified_at: Time.current)
    @conn.update!(enforce: true)
    @app = Doorkeeper::Application.create!(name: "React", uid: "react-uid", redirect_uri: "urn:ietf:wg:oauth:2.0:oob")
    users(:member_user).update!(password: "Password123!")
  end

  def refusal = { "error" => "Sign in with your organisation's SSO.", "sso_connection_id" => @conn.id }

  test "password grant is refused for an enforced domain" do
    post "/oauth/token", params: { grant_type: "password", email: "member@example.com", password: "Password123!",
                                   client_id: @app.uid, client_secret: @app.secret }, headers: { "Host" => api_host }
    assert_response :forbidden
    assert_equal refusal, JSON.parse(response.body)
  end

  test "password grant works when enforce is off" do
    @conn.update!(enforce: false)
    post "/oauth/token", params: { grant_type: "password", email: "member@example.com", password: "Password123!",
                                   client_id: @app.uid, client_secret: @app.secret }, headers: { "Host" => api_host }
    assert_response :ok
  end

  test "super admins are exempt" do
    users(:super_admin_user).update!(super_admin: true, email: "root@example.com", password: "Password123!")
    post "/oauth/token", params: { grant_type: "password", email: "root@example.com", password: "Password123!",
                                   client_id: @app.uid, client_secret: @app.secret }, headers: { "Host" => api_host }
    assert_response :ok
  end

  test "a lapsed entitlement lifts enforcement" do
    unentitle!(@instance)
    assert_nil SsoEnforcement.enforced_connection_id("member@example.com")
  end

  test "public sign-up is refused for an enforced domain" do
    post "#{API_PREFIX}/users", params: { email: "new@example.com", password: "Password123!", name: "N", client_id: @app.uid },
                                headers: { "Host" => api_host }
    assert_response :forbidden
    assert_equal refusal, JSON.parse(response.body)
  end

  test "reset_password is refused for an enforced domain" do
    post "#{API_PREFIX}/users/reset_password", params: { email: "member@example.com" }, headers: { "Host" => api_host }
    assert_response :forbidden
  end

  test "change_password is refused when the token belongs to an enforced domain" do
    raw = users(:member_user).send(:set_reset_password_token)
    post "#{API_PREFIX}/users/change_password", params: { reset_token: raw, new_password: "Another123!" }, headers: { "Host" => api_host }
    assert_response :forbidden
  end

  test "accept_invite is refused for an enforced domain" do
    invitee = User.invite!({ email: "invitee@example.com", skip_invitation: true }, users(:admin_user))
    post "#{API_PREFIX}/users/accept_invite", params: { invitation_token: invitee.raw_invitation_token, password: "Password123!",
                                                        name: "I", client_id: @app.uid }, headers: { "Host" => api_host }
    assert_response :forbidden
  end

  test "social login is refused for an enforced domain" do
    info = OpenStruct.new(display_name: "M", name: "M", email: "member@example.com")
    auth = OpenStruct.new(provider: "google_oauth2", uid: "g1", info: info, extra: OpenStruct.new(raw_info: {}))
    err = assert_raises(RuntimeError) { SsoAuthenticationService.find_or_create_from_auth(auth_hash: auth) }
    assert_match(/organisation's SSO/, err.message)
  end

  test "rake sso:disable_enforce turns enforcement off" do
    Rails.application.load_tasks unless Rake::Task.task_defined?("sso:disable_enforce")
    Rake::Task["sso:disable_enforce"].reenable
    Rake::Task["sso:disable_enforce"].invoke(@instance.id.to_s)
    assert_not @conn.reload.enforce
  end
end
