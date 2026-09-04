require "test_helper"
require_relative "../../../test/integration/auth_test_helper"

class AuditTenantActionsTest < ActionDispatch::IntegrationTest
  include AuthTestHelper
  include AuditTestHelper

  fixtures :instances, :users, :instance_roles, :projects, :domains, :redirect_configs, :redirects,
           :applications, :ios_configurations, :links, :campaigns

  setup do
    @instance = instances(:one)
    @admin = users(:admin_user)
    @project = @instance.production
    entitle!(@instance)
    @headers = doorkeeper_headers_for(@admin)
  end

  def actions
    AuditEvent.where(instance_id: @instance.id).order(:sequence).pluck(:action)
  end

  test "member added and removed" do
    post "#{API_PREFIX}/instances/#{@instance.id}/members", params: { email: "new@example.com", role: "member" }, headers: @headers
    assert_response :ok
    delete "#{API_PREFIX}/instances/#{@instance.id}/members", params: { email: "new@example.com" }, headers: @headers
    assert_response :ok
    assert_equal %w[instance.member_added instance.member_removed], actions
    removed = AuditEvent.find_by(instance_id: @instance.id, action: "instance.member_removed")
    assert_equal "new@example.com", removed.target["email"]
    assert_equal "member", removed.changes_data["before"]["role"]
  end

  test "redirect config update carries a diff" do
    put "#{API_PREFIX}/projects/#{@project.id}/redirect_config", params: { default_fallback: "https://example.com/new" }, headers: @headers
    assert_response :ok
    ev = AuditEvent.find_by(instance_id: @instance.id, action: "redirect_config.updated")
    assert_equal "https://example.com/new", ev.changes_data["after"]["default_fallback"]
  end

  test "ios configuration update is audited with its params" do
    put "#{API_PREFIX}/instances/#{@instance.id}/configurations/ios",
        params: { enabled: true, bundle_id: "com.x.y", app_prefix: "ABC" }, headers: @headers
    assert_response :ok
    ev = AuditEvent.find_by(instance_id: @instance.id, action: "ios_configuration.updated")
    assert_equal "com.x.y", ev.changes_data["after"]["bundle_id"]
  end

  test "link create, update and delete" do
    post "#{API_PREFIX}/projects/#{@project.id}/links", params: { title: "T", path: "audited-path" }, headers: @headers
    assert_response :ok
    link = Link.find_by(path: "audited-path")
    patch "#{API_PREFIX}/projects/#{@project.id}/links/#{link.id}", params: { title: "T2" }, headers: @headers
    assert_response :ok
    delete "#{API_PREFIX}/projects/#{@project.id}/links/#{link.id}", headers: @headers
    assert_response :ok
    assert_equal %w[link.created link.updated link.deleted], actions
    updated = AuditEvent.find_by(instance_id: @instance.id, action: "link.updated")
    assert_equal "T", updated.changes_data["before"]["title"]
    assert_equal "T2", updated.changes_data["after"]["title"]
  end

  test "export is audited" do
    post "#{API_PREFIX}/projects/#{@project.id}/exports/links", params: { active: true, sdk: false }, headers: @headers
    assert_response :accepted
    assert_includes actions, "export.link_data"
  end

  test "instance deletion request is audited before the job runs" do
    delete "#{API_PREFIX}/instances/#{@instance.id}", headers: @headers
    assert_response :ok
    assert_includes actions, "instance.deletion_requested"
  end

  test "an invalid UTF-8 user agent is scrubbed, not a 500" do
    put "#{API_PREFIX}/projects/#{@project.id}/redirect_config",
        params: { default_fallback: "https://example.com/ua" },
        headers: @headers.merge("User-Agent" => "Mozilla \xE9 legacy".b)
    assert_response :ok
    ev = AuditEvent.find_by(instance_id: @instance.id, action: "redirect_config.updated")
    assert ev.user_agent.valid_encoding?
    assert_includes ev.user_agent, "?"
  end

  # Contract check skipped: this test deliberately provokes a 500, which no contract lists.
  test "a failing audit rolls back the primary write" do
    original = ENV["SKIP_API_CONTRACTS"]
    ENV["SKIP_API_CONTRACTS"] = "true"
    before = @project.redirect_config.default_fallback
    AuditEvent.stub(:record, ->(*, **) { raise "audit down" }) do
      put "#{API_PREFIX}/projects/#{@project.id}/redirect_config",
          params: { default_fallback: "https://example.com/rolled-back" }, headers: @headers
    end
    assert_response :internal_server_error
    assert_equal before, @project.reload.redirect_config.default_fallback
  ensure
    original.nil? ? ENV.delete("SKIP_API_CONTRACTS") : ENV["SKIP_API_CONTRACTS"] = original
  end
end
