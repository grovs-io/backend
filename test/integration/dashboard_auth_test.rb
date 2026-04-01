require "test_helper"
require_relative "auth_test_helper"

class DashboardAuthTest < ActionDispatch::IntegrationTest
  include AuthTestHelper

  fixtures :instances, :users, :instance_roles, :projects, :domains, :redirect_configs

  setup do
    @instance_one = instances(:one)
    @instance_two = instances(:two)
    @admin_user = users(:admin_user)
    @member_user = users(:member_user)
    @super_admin = users(:super_admin_user)
    @project_one = projects(:one)
    @project_two = projects(:two)
  end

  # --- No Token ---

  test "request without token returns 401 with no data" do
    get "#{API_PREFIX}/instances", headers: api_headers
    assert_response :unauthorized
    assert_no_match(/instances/, response.body, "401 response must not leak instance data")
  end

  # --- Expired Token ---

  test "request with expired token returns 401 with no data" do
    headers = expired_doorkeeper_headers_for(@admin_user)
    get "#{API_PREFIX}/instances", headers: headers
    assert_response :unauthorized
    assert_no_match(/instances/, response.body, "expired token response must not leak data")
  end

  # --- Valid Token, List Instances ---

  test "valid token returns only instances user belongs to" do
    headers = doorkeeper_headers_for(@admin_user)
    get "#{API_PREFIX}/instances", headers: headers
    assert_response :ok
    json = JSON.parse(response.body)
    assert json.key?("instances")
    instance_ids = json["instances"].map { |i| i["id"] }
    assert_includes instance_ids, @instance_one.id
    assert_not_includes instance_ids, @instance_two.id, "must not return instances user doesn't belong to"
  end

  # --- Instance Access (Member) ---

  test "member can access their instance details with correct data" do
    headers = doorkeeper_headers_for(@member_user)
    get "#{API_PREFIX}/instances/#{@instance_one.id}", headers: headers
    assert_response :ok
    json = JSON.parse(response.body)
    assert_equal @instance_one.id, json["instance"]["id"]
    assert json.key?("get_started_setup"), "instance details must include get_started_setup"
  end

  # --- Instance Access (Non-Member) ---

  test "user not in instance gets 403 with no data leak" do
    headers = doorkeeper_headers_for(@admin_user)
    get "#{API_PREFIX}/instances/#{@instance_two.id}", headers: headers
    assert_response :forbidden
    json = JSON.parse(response.body)
    assert_not json.key?("instance"), "403 response must not contain instance data"
    assert_not json.key?("get_started_setup"), "403 response must not contain setup data"
  end

  # --- Project Access (Member of Instance) ---

  test "admin can access project in their instance" do
    headers = doorkeeper_headers_for(@admin_user)
    post "#{API_PREFIX}/projects/#{@project_one.id}/links/search",
      params: { active: "true", sdk: "false" },
      headers: headers
    assert_response :ok
    json = JSON.parse(response.body)
    assert_kind_of Array, json["data"], "search response must contain data array"
    assert json.key?("total_entries"), "must include pagination total_entries"
    assert json.key?("page"), "must include pagination page"
  end

  # --- Tenant Isolation ---

  test "user from instance_one cannot access instance_two project and gets no data" do
    headers = doorkeeper_headers_for(@admin_user)
    post "#{API_PREFIX}/projects/#{@project_two.id}/links/search",
      params: { active: "true", sdk: "false" },
      headers: headers
    assert_response :forbidden
    json = JSON.parse(response.body)
    assert_equal "Forbidden", json["error"]
    assert_not json.key?("data"), "403 must not leak link data from other tenant"
  end

  # --- Admin-Only Endpoints ---

  test "member cannot delete instance and gets 403" do
    headers = doorkeeper_headers_for(@member_user)
    assert_no_difference "Instance.count" do
      delete "#{API_PREFIX}/instances/#{@instance_one.id}", headers: headers
    end
    assert_response :forbidden
  end

  test "admin can delete instance and roles are removed" do
    headers = doorkeeper_headers_for(@admin_user)
    # Deletion is async (DeleteInstanceJob), but roles are removed synchronously
    assert_difference "InstanceRole.where(instance_id: #{@instance_one.id}).count", -2 do
      delete "#{API_PREFIX}/instances/#{@instance_one.id}", headers: headers
    end
    assert_response :ok
    assert_equal 0, InstanceRole.where(instance_id: @instance_one.id).count,
      "all instance roles must be removed"
  end

  # --- Nonexistent Resource ---

  test "nonexistent project returns 404 with error message" do
    headers = doorkeeper_headers_for(@admin_user)
    post "#{API_PREFIX}/projects/nonexistent123/links/search",
      params: { active: "true", sdk: "false" },
      headers: headers
    assert_response :not_found
    json = JSON.parse(response.body)
    assert json["error"].present?, "must return descriptive error message"
    assert_not json.key?("data"), "404 must not leak data"
  end

  test "nonexistent instance returns 404 with error message" do
    headers = doorkeeper_headers_for(@admin_user)
    get "#{API_PREFIX}/instances/nonexistent123", headers: headers
    assert_response :not_found
    json = JSON.parse(response.body)
    assert json["error"].present?, "must return descriptive error message"
    assert_not json.key?("instance"), "404 must not leak instance data"
  end
end
