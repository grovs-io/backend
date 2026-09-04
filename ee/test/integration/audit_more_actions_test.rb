require "test_helper"
require_relative "../../../test/integration/auth_test_helper"

class AuditMoreActionsTest < ActionDispatch::IntegrationTest
  include AuthTestHelper
  include AuditTestHelper

  fixtures :instances, :users, :instance_roles, :projects, :domains, :redirect_configs, :redirects,
           :applications, :ios_configurations, :android_configurations, :web_configurations, :mcp_tokens

  ADMIN_KEY = "audit-admin-key".freeze

  setup do
    @instance = instances(:one)
    @admin = users(:admin_user)
    @project = @instance.production
    entitle!(@instance)
    @headers = doorkeeper_headers_for(@admin)
  end

  def event(action)
    AuditEvent.where(instance_id: @instance.id, action: action).order(:sequence).last
  end

  test "instance rename carries the project name diff" do
    put "#{API_PREFIX}/instances/#{@instance.id}", params: { name: "Renamed" }, headers: @headers
    assert_response :ok
    assert_equal "Renamed", event("instance.renamed").changes_data["after"]["name"]
  end

  test "platform redirect update names platform and variation" do
    put "#{API_PREFIX}/projects/#{@project.id}/redirect_config/redirect",
        params: { platform: "ios", variation: "phone", fallback_url: "https://ios.example.com", appstore: false, enabled: true }, headers: @headers
    assert_response :ok
    ev = event("redirect.updated")
    assert_equal "ios", ev.target["platform"]
    assert_equal "https://ios.example.com", ev.changes_data["after"]["fallback_url"]
  end

  test "domain update and google tracking id carry a real before/after" do
    put "#{API_PREFIX}/projects/#{@project.id}/domain", params: { generic_title: "Audited Title" }, headers: @headers
    assert_response :ok
    ev = event("domain.updated")
    assert_equal "Audited Title", ev.changes_data["after"]["generic_title"]
    assert ev.changes_data["before"].key?("generic_title")

    put "#{API_PREFIX}/projects/#{@project.id}/domain/google_tracking_id", params: { google_tracking_id: "G-AUDIT" }, headers: @headers
    assert_response :ok
    assert_equal "G-AUDIT", event("domain.google_tracking_id_updated").changes_data["after"]["google_tracking_id"]
  end

  test "android, web and desktop configuration set and remove" do
    put "#{API_PREFIX}/instances/#{@instance.id}/configurations/android",
        params: { enabled: true, identifier: "com.audit.app", sha256s: ["AA:BB"] }, headers: @headers
    assert_response :ok
    assert_equal "com.audit.app", event("android_configuration.updated").changes_data["after"]["identifier"]
    delete "#{API_PREFIX}/instances/#{@instance.id}/configurations/android", headers: @headers
    assert_response :ok
    assert_not_nil event("android_configuration.removed")

    put "#{API_PREFIX}/instances/#{@instance.id}/configurations/web", params: { enabled: true, domains: ["audit.example.com"] }, headers: @headers
    assert_response :ok
    assert_not_nil event("web_configuration.updated")
    delete "#{API_PREFIX}/instances/#{@instance.id}/configurations/web", headers: @headers
    assert_response :ok
    assert_not_nil event("web_configuration.removed")

    put "#{API_PREFIX}/instances/#{@instance.id}/configurations/desktop",
        params: { enabled: true, generated_page: true, fallback_url: "https://desk.example.com" }, headers: @headers
    assert_response :ok
    assert_not_nil event("desktop_configuration.updated")
    delete "#{API_PREFIX}/instances/#{@instance.id}/configurations/desktop", headers: @headers
    assert_response :ok
    assert_not_nil event("desktop_configuration.removed")
  end

  test "usage export is audited" do
    post "#{API_PREFIX}/instances/#{@instance.id}/exports/usage", params: {}, headers: @headers
    assert_response :accepted
    assert_not_nil event("export.usage_data")
  end

  test "dashboard mcp token revocation is audited with the token as target" do
    token = McpToken.new(user: @admin, name: "Audit MCP")
    token.generate_token
    token.save!
    delete "#{API_PREFIX}/mcp/tokens/#{token.hashid}", headers: @headers
    assert_response :ok
    ev = event("mcp_token.revoked")
    assert_equal "Audit MCP", ev.target["name"]
    assert_equal "dashboard", ev.actor["via"]
  end

  test "password change via reset token and 2fa disable are audited" do
    raw = @admin.send(:set_reset_password_token)
    post "#{API_PREFIX}/users/change_password", params: { reset_token: raw, new_password: "NewSecurePassword123!" }, headers: api_headers
    assert_response :ok
    assert_not_nil event("user.password_changed")

    @admin.update!(otp_secret: User.generate_otp_secret, otp_required_for_login: true)
    put "#{API_PREFIX}/users/me/two_factor", params: { enable_2fa: false, otp_code: @admin.current_otp }, headers: doorkeeper_headers_for(@admin)
    assert_response :ok
    assert_not_nil event("user.2fa_disabled")
  end

  test "enterprise subscription creation and deactivation are both audited" do
    other = instances(:two)
    with_admin_key do
      post "#{API_PREFIX}/admin/create_enterprise_subscription",
           params: { instance_id: other.id, start_date: "2026-01-01", end_date: "2027-01-01", total_maus: 100, active: true },
           headers: api_headers.merge("X-AUTH" => ADMIN_KEY)
      assert_response :created
      created = AuditEvent.find_by(instance_id: other.id, action: "enterprise_subscription.created")
      assert_equal "admin_key", created.actor["type"]

      patch "#{API_PREFIX}/admin/update_enterprise_subscription",
            params: { id: other.enterprise_subscription.id, active: false }, headers: api_headers.merge("X-AUTH" => ADMIN_KEY)
      assert_response :ok
      updated = AuditEvent.find_by(instance_id: other.id, action: "enterprise_subscription.updated")
      assert_not_nil updated, "deactivation must be recorded even though the instance is no longer entitled"
      assert_equal false, updated.changes_data["after"]["active"]
    end
  end

  test "trailing rows deleted from the chain fail verification" do
    put "#{API_PREFIX}/instances/#{@instance.id}", params: { name: "A" }, headers: @headers
    put "#{API_PREFIX}/instances/#{@instance.id}", params: { name: "B" }, headers: @headers
    AuditEvent.connection.execute("DELETE FROM audit_events WHERE instance_id = #{@instance.id} AND sequence = 2")
    assert_equal false, AuditEvent.verify_chain(@instance.id)[:ok]
  end

  private

  def with_admin_key
    original = ENV["ADMIN_API_KEY"]
    ENV["ADMIN_API_KEY"] = ADMIN_KEY
    yield
  ensure
    ENV["ADMIN_API_KEY"] = original
  end
end
