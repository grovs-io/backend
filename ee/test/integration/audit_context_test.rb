require "test_helper"
require_relative "../../../test/integration/auth_test_helper"

class AuditContextTest < ActionDispatch::IntegrationTest
  include AuthTestHelper
  include AuditTestHelper

  fixtures :instances, :users, :instance_roles, :projects, :domains

  setup do
    @instance = instances(:one)
    @admin = users(:admin_user)
    entitle!(@instance)
  end

  test "a dashboard mutation records a user actor with ip and request id" do
    put "#{API_PREFIX}/instances/#{@instance.id}/revenue_collection",
        params: { revenue_collection_enabled: false }, headers: doorkeeper_headers_for(@admin)
    assert_response :ok
    ev = AuditEvent.where(instance_id: @instance.id, action: "instance.revenue_collection_changed").last
    assert_not_nil ev
    assert_equal "user", ev.actor["type"]
    assert_equal @admin.id, ev.actor["id"]
    assert_equal "dashboard", ev.actor["via"]
    assert_equal "127.0.0.1", ev.ip
    assert ev.request_id.present?
    assert_equal true, ev.changes_data["before"]["revenue_collection_enabled"]
    assert_equal false, ev.changes_data["after"]["revenue_collection_enabled"]
  end

  test "an admin-key mutation records an admin_key actor" do
    ENV["ADMIN_API_KEY"] = "adminkey"
    patch "#{API_PREFIX}/admin/instance_retention",
          params: { instance_id: @instance.id, delete_days: 800 }, headers: api_headers.merge("X-AUTH" => "adminkey")
    assert_response :ok
    ev = AuditEvent.where(instance_id: @instance.id, action: "instance.retention_changed").last
    assert_equal "admin_key", ev.actor["type"]
    assert_equal 730, ev.changes_data["before"]["delete_days"]
    assert_equal 800, ev.changes_data["after"]["delete_days"]
  ensure
    ENV.delete("ADMIN_API_KEY")
  end
end
