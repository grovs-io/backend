require "test_helper"
require_relative "../../../test/integration/auth_test_helper"

class AuditEventsApiTest < ActionDispatch::IntegrationTest
  include AuthTestHelper
  include AuditTestHelper

  fixtures :instances, :users, :instance_roles

  setup do
    @instance = instances(:one)
    @admin = users(:admin_user)
    @member = users(:member_user)
    entitle!(@instance)
    %w[link.created link.updated link.deleted].each { |a| AuditEvent.record(instance_id: @instance.id, action: a, actor: AuditActor.system("test")) }
    @token = AuditExportToken.new(instance: @instance, created_by_user: @admin, name: "Splunk")
    @plain = @token.generate_token
    @token.save!
  end

  test "cursors parse as decimal, not octal" do
    9.times { AuditEvent.record(instance_id: @instance.id, action: "link.updated", actor: AuditActor.system("test")) }
    get "#{API_PREFIX}/instances/#{@instance.id}/audit_events", params: { after: "010" },
        headers: doorkeeper_headers_for(@admin)
    assert_response :ok
    assert_equal [11, 12], JSON.parse(response.body)["events"].map { |e| e["sequence"] }
  end

  test "admin lists events ordered by sequence with a cursor" do
    get "#{API_PREFIX}/instances/#{@instance.id}/audit_events", params: { after: 1, limit: 1 },
        headers: doorkeeper_headers_for(@admin)
    assert_response :ok
    json = JSON.parse(response.body)
    assert_equal 1, json["schema_version"]
    assert_equal [2], json["events"].map { |e| e["sequence"] }
    assert_equal 2, json["next_after"]
    assert_equal "link.updated", json["events"][0]["action"]
    assert json["events"][0]["hash"].present?
  end

  test "member is forbidden" do
    get "#{API_PREFIX}/instances/#{@instance.id}/audit_events", headers: doorkeeper_headers_for(@member)
    assert_response :forbidden
  end

  test "export token can pull and its last_used_at is stamped" do
    get "#{API_PREFIX}/instances/#{@instance.id}/audit_events",
        headers: api_headers.merge("Authorization" => "Bearer #{@plain}")
    assert_response :ok
    assert_equal 3, JSON.parse(response.body)["events"].size
    assert_not_nil @token.reload.last_used_at
  end

  test "export token of another instance is forbidden" do
    other = instances(:two)
    get "#{API_PREFIX}/instances/#{other.id}/audit_events",
        headers: api_headers.merge("Authorization" => "Bearer #{@plain}")
    assert_response :forbidden
  end

  test "revoked export token is unauthorized" do
    @token.revoke!
    get "#{API_PREFIX}/instances/#{@instance.id}/audit_events",
        headers: api_headers.merge("Authorization" => "Bearer #{@plain}")
    assert_response :unauthorized
  end

  test "head returns latest sequence and hash" do
    get "#{API_PREFIX}/instances/#{@instance.id}/audit_events/head", headers: doorkeeper_headers_for(@admin)
    assert_response :ok
    json = JSON.parse(response.body)
    assert_equal 3, json["sequence"]
    assert_equal AuditEvent.where(instance_id: @instance.id).order(:sequence).last.hash_value, json["hash"]
  end

  test "unentitled instance gets 403 even for admins" do
    unentitle!(@instance)
    get "#{API_PREFIX}/instances/#{@instance.id}/audit_events", headers: doorkeeper_headers_for(@admin)
    assert_response :forbidden
  end

  test "limit is capped at 1000 and filters by action" do
    get "#{API_PREFIX}/instances/#{@instance.id}/audit_events", params: { limit: 5000, event_action: "link.deleted" },
        headers: doorkeeper_headers_for(@admin)
    assert_response :ok
    assert_equal ["link.deleted"], JSON.parse(response.body)["events"].map { |e| e["action"] }
  end

  test "order=desc pages newest first with the before cursor" do
    get "#{API_PREFIX}/instances/#{@instance.id}/audit_events", params: { order: "desc", limit: 2 },
        headers: doorkeeper_headers_for(@admin)
    assert_response :ok
    json = JSON.parse(response.body)
    assert_equal [3, 2], json["events"].map { |e| e["sequence"] }
    assert_equal 3, json["next_after"]
    assert_equal 2, json["next_before"]

    get "#{API_PREFIX}/instances/#{@instance.id}/audit_events", params: { order: "desc", limit: 2, before: json["next_before"] },
        headers: doorkeeper_headers_for(@admin)
    assert_equal [1], JSON.parse(response.body)["events"].map { |e| e["sequence"] }
  end

  test "invalid order is 400" do
    get "#{API_PREFIX}/instances/#{@instance.id}/audit_events", params: { order: "sideways" }, headers: doorkeeper_headers_for(@admin)
    assert_response :bad_request
  end

  test "unauthenticated request is 401, not 500" do
    get "#{API_PREFIX}/instances/#{@instance.id}/audit_events", headers: api_headers
    assert_response :unauthorized
    get "#{API_PREFIX}/instances/#{@instance.id}/audit_events/head", headers: api_headers
    assert_response :unauthorized
  end

  test "unknown instance is 404" do
    get "#{API_PREFIX}/instances/999999/audit_events", headers: doorkeeper_headers_for(@admin)
    assert_response :not_found
  end
end
