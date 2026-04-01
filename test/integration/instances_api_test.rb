require "test_helper"
require_relative "auth_test_helper"

class InstancesApiTest < ActionDispatch::IntegrationTest
  include AuthTestHelper

  fixtures :instances, :users, :instance_roles, :projects, :domains,
           :redirect_configs, :applications, :ios_configurations,
           :android_configurations, :web_configurations

  setup do
    @admin_user = users(:admin_user)
    @member_user = users(:member_user)
    @super_admin = users(:super_admin_user)
    @instance = instances(:one)
    @instance_two = instances(:two)
  end

  # --- List Instances ---

  test "list returns only instances user belongs to" do
    headers = doorkeeper_headers_for(@admin_user)
    get "#{API_PREFIX}/instances", headers: headers
    assert_response :ok
    json = JSON.parse(response.body)
    instance_ids = json["instances"].map { |i| i["id"] }
    assert_includes instance_ids, @instance.id
    assert_not_includes instance_ids, @instance_two.id, "must not return instances user doesn't belong to"
  end

  # --- Instance Details ---

  test "member gets correct instance details with all SDK setup flags" do
    headers = doorkeeper_headers_for(@member_user)
    get "#{API_PREFIX}/instances/#{@instance.id}", headers: headers
    assert_response :ok
    json = JSON.parse(response.body)
    assert_equal @instance.id, json["instance"]["id"]

    setup = json["get_started_setup"]
    assert setup.key?("ios_sdk"), "must include ios_sdk flag"
    assert setup.key?("android_sdk"), "must include android_sdk flag"
    assert setup.key?("web_sdk"), "must include web_sdk flag"

    # Instance :one has ios, android, and web configurations via fixtures
    assert_equal true, setup["ios_sdk"], "ios_sdk should be true when configuration exists"
    assert_equal true, setup["android_sdk"], "android_sdk should be true when configuration exists"
    assert_equal true, setup["web_sdk"], "web_sdk should be true when configuration exists"
  end

  test "get_started_setup reports false for SDKs without configuration" do
    headers = doorkeeper_headers_for(@super_admin)
    # Instance :two has only an ios_app (second_ios_app) with no configuration
    get "#{API_PREFIX}/instances/#{@instance_two.id}", headers: headers
    assert_response :ok
    setup = JSON.parse(response.body)["get_started_setup"]

    assert_equal false, setup["ios_sdk"], "ios_sdk should be false without configuration"
    assert_equal false, setup["android_sdk"], "android_sdk should be false without application"
    assert_equal false, setup["web_sdk"], "web_sdk should be false without application"
  end

  test "non-member gets 403 with no data leak" do
    headers = doorkeeper_headers_for(@admin_user)
    get "#{API_PREFIX}/instances/#{@instance_two.id}", headers: headers
    assert_response :forbidden
    json = JSON.parse(response.body)
    assert_not json.key?("instance"), "403 must not contain instance data"
    assert_not json.key?("get_started_setup"), "403 must not leak setup data"
  end

  # --- Add Member (Admin-Only) ---

  test "admin can add member and role is persisted" do
    headers = doorkeeper_headers_for(@admin_user)
    assert_difference "InstanceRole.count", 1 do
      post "#{API_PREFIX}/instances/#{@instance.id}/members",
        params: { email: "newmember@example.com", role: "member" },
        headers: headers
    end
    assert_response :ok
    json = JSON.parse(response.body)
    assert_equal "member", json["role_added"]["role"]

    new_user = User.find_by(email: "newmember@example.com")
    assert_not_nil new_user
    assert InstanceRole.exists?(user_id: new_user.id, instance_id: @instance.id)
  end

  test "member cannot add member (admin-only) and no role is created" do
    headers = doorkeeper_headers_for(@member_user)
    assert_no_difference "InstanceRole.count" do
      post "#{API_PREFIX}/instances/#{@instance.id}/members",
        params: { email: "another@example.com", role: "member" },
        headers: headers
    end
    assert_response :forbidden
  end

  # --- Remove Member (Admin-Only) ---

  test "admin can remove member and role is deleted" do
    headers = doorkeeper_headers_for(@admin_user)
    assert_difference "InstanceRole.count", -1 do
      delete "#{API_PREFIX}/instances/#{@instance.id}/members",
        params: { email: @member_user.email },
        headers: headers
    end
    assert_response :ok
    assert_equal "User deleted", JSON.parse(response.body)["message"]
    assert_not InstanceRole.exists?(user_id: @member_user.id, instance_id: @instance.id),
      "member role must be removed from DB"
  end

  test "admin cannot remove self" do
    headers = doorkeeper_headers_for(@admin_user)
    assert_no_difference "InstanceRole.count" do
      delete "#{API_PREFIX}/instances/#{@instance.id}/members",
        params: { email: @admin_user.email },
        headers: headers
    end
    assert_response :forbidden
  end

  # --- Revenue Collection Toggle ---

  test "member can toggle revenue collection and value persists" do
    headers = doorkeeper_headers_for(@member_user)
    put "#{API_PREFIX}/instances/#{@instance.id}/revenue_collection",
      params: { revenue_collection_enabled: true },
      headers: headers
    assert_response :ok
    json = JSON.parse(response.body)
    assert json["instance"]["revenue_collection_enabled"]

    @instance.reload
    assert @instance.revenue_collection_enabled, "value must persist in DB"
  end

  # --- Members List ---

  test "member can list instance members with correct data" do
    headers = doorkeeper_headers_for(@member_user)
    get "#{API_PREFIX}/instances/#{@instance.id}/members", headers: headers
    assert_response :ok
    json = JSON.parse(response.body)
    assert_kind_of Array, json["members"]
    # Members are serialized as {role:, user: {email:, ...}}
    emails = json["members"].map { |m| m.dig("user", "email") }
    assert_includes emails, @admin_user.email
    assert_includes emails, @member_user.email
  end

  # --- User Role ---

  test "user gets correct role for instance" do
    headers = doorkeeper_headers_for(@member_user)
    get "#{API_PREFIX}/instances/#{@instance.id}/role", headers: headers
    assert_response :ok
    json = JSON.parse(response.body)
    assert_equal "member", json["role"]["role"]
  end

  # --- Delete Instance (Admin-Only) ---

  test "member cannot delete instance and record persists" do
    headers = doorkeeper_headers_for(@member_user)
    assert_no_difference "Instance.count" do
      delete "#{API_PREFIX}/instances/#{@instance.id}", headers: headers
    end
    assert_response :forbidden
  end

  test "admin can delete instance and roles are removed" do
    headers = doorkeeper_headers_for(@admin_user)
    # Instance deletion is async (DeleteInstanceJob), but roles are removed synchronously
    role_count = InstanceRole.where(instance_id: @instance.id).count
    assert role_count > 0, "precondition: instance must have roles"

    delete "#{API_PREFIX}/instances/#{@instance.id}", headers: headers
    assert_response :ok
    assert_equal "Instance deleted", JSON.parse(response.body)["message"]
    assert_equal 0, InstanceRole.where(instance_id: @instance.id).count,
      "all instance roles must be removed synchronously"
  end
end
