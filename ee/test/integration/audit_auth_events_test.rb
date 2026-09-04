require "test_helper"
require "sidekiq/testing"
require_relative "../../../test/integration/auth_test_helper"

class AuditAuthEventsTest < ActionDispatch::IntegrationTest
  include AuthTestHelper
  include AuditTestHelper

  fixtures :instances, :users, :instance_roles, :projects, :domains, :applications

  setup do
    @instance = instances(:one)
    @user = users(:admin_user)
    @password = "SecurePassword123!"
    @user.update!(password: @password, password_confirmation: @password)
    entitle!(@instance)
    @client_app = Doorkeeper::Application.create!(name: "React", redirect_uri: "urn:ietf:wg:oauth:2.0:oob")
  end

  def login(password)
    post "/oauth/token", params: { grant_type: "password", email: @user.email, password: password,
                                   client_id: @client_app.uid, client_secret: @client_app.secret }
  end

  test "successful password login is audited with via password" do
    login(@password)
    assert_response :ok
    ev = AuditEvent.find_by(instance_id: @instance.id, action: "user.login")
    assert_equal "password", ev.actor["via"]
    assert_equal @user.id, ev.actor["id"]
  end

  test "failed login is audited as login_failed with outcome failure" do
    login("wrong")
    assert_response :bad_request
    ev = AuditEvent.find_by(instance_id: @instance.id, action: "user.login_failed")
    assert_equal "failure", ev.outcome
    assert_equal @user.email, ev.actor["email"]
  end

  test "unknown email failure writes nothing" do
    post "/oauth/token", params: { grant_type: "password", email: "nobody@example.com", password: "x",
                                   client_id: @client_app.uid, client_secret: @client_app.secret }
    assert_equal 0, AuditEvent.count
  end

  test "refresh grant is not a login" do
    login(@password)
    refresh = JSON.parse(response.body)["refresh_token"]
    post "/oauth/token", params: { grant_type: "refresh_token", refresh_token: refresh,
                                   client_id: @client_app.uid, client_secret: @client_app.secret }
    assert_response :ok
    assert_equal 1, AuditEvent.where(action: "user.login").count
  end

  test "revoke is audited as logout" do
    login(@password)
    token = JSON.parse(response.body)["access_token"]
    post "/oauth/revoke", params: { token: token }
    assert_response :ok
    assert_equal 1, AuditEvent.where(instance_id: @instance.id, action: "user.logout").count
  end

  test "2fa toggle and password reset request are audited" do
    headers = doorkeeper_headers_for(@user)
    @user.update!(otp_secret: User.generate_otp_secret)
    code = @user.current_otp
    put "#{API_PREFIX}/users/me/two_factor", params: { enable_2fa: true, otp_code: code }, headers: headers
    assert_response :ok
    assert_equal 1, AuditEvent.where(action: "user.2fa_enabled").count

    post "#{API_PREFIX}/users/reset_password", params: { email: @user.email }, headers: api_headers
    assert_response :ok
    assert_equal 1, AuditEvent.where(action: "user.password_reset_requested").count
  end

  test "member account deletion is audited before the roles disappear" do
    member = users(:member_user)
    delete "#{API_PREFIX}/users/me", headers: doorkeeper_headers_for(member)
    assert_response :ok
    ev = AuditEvent.find_by(instance_id: @instance.id, action: "user.account_deleted")
    assert_equal member.id, ev.actor["id"]
  end

  test "sole-admin account deletion requests tenant deletion and audits both" do
    Sidekiq::Testing.fake! do
      DeleteInstanceJob.jobs.clear
      delete "#{API_PREFIX}/users/me", headers: doorkeeper_headers_for(@user)
      assert_response :ok
      assert_equal [@instance.id], DeleteInstanceJob.jobs.map { |j| j["args"][0] }
    end
    assert AuditEvent.exists?(instance_id: @instance.id, action: "user.account_deleted")
    requested = AuditEvent.find_by(instance_id: @instance.id, action: "instance.deletion_requested")
    assert_equal @user.id, requested.actor["id"]
  end
end
