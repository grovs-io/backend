require "test_helper"
require_relative "../mcp_auth_test_helper"

class McpProjectsTest < ActionDispatch::IntegrationTest
  include McpAuthTestHelper

  fixtures :instances, :users, :instance_roles, :projects

  setup do
    @admin_user = users(:admin_user)
    @admin_headers = create_mcp_headers_for(@admin_user)
  end

  test "create_project creates instance with full InstanceSerializer schema" do
    headers = @admin_headers
    assert_difference "Instance.count", 1 do
      post "#{MCP_PREFIX}/projects",
        params: { name: "New MCP Project" },
        headers: headers
    end
    assert_response :created
    json = json_response
    inst = json["instance"]

    # InstanceSerializer base attributes
    assert inst["id"].present?
    assert inst["api_key"].present?
    assert inst["uri_scheme"].present?
    assert inst["updated_at"].present?
    assert inst["hash_id"].present?
    assert_equal false, inst["quota_exceeded"]

    # Nested ProjectSerializer for production
    prod = inst["production"]
    assert prod.present?
    assert prod["id"].present?
    assert_equal "New MCP Project", prod["name"]
    assert_equal false, prod["test"]
    assert prod["hash_id"].present?
    assert prod["domain"].present?, "newly created project should have a domain"

    # Nested ProjectSerializer for test
    test_proj = inst["test"]
    assert test_proj.present?
    assert test_proj["id"].present?
    assert_equal true, test_proj["test"]
    assert test_proj["hash_id"].present?
  end

  test "create_project creates both production and test projects" do
    headers = @admin_headers
    assert_difference "Project.count", 2 do
      post "#{MCP_PREFIX}/projects",
        params: { name: "Dual Env Project" },
        headers: headers
    end
    assert_response :created
    json = json_response

    new_instance = Instance.find(json["instance"]["id"])
    assert new_instance.production.present?, "should have a production project"
    assert new_instance.test.present?, "should have a test project"
    assert_equal false, new_instance.production.test?
    assert_equal true, new_instance.test.test?
  end

  test "create_project with blank name returns 400" do
    headers = @admin_headers
    # Rails params.require(:name) raises ParameterMissing for blank strings -> 400
    assert_no_difference "Instance.count" do
      post "#{MCP_PREFIX}/projects",
        params: { name: "" },
        headers: headers
    end
    assert_response :bad_request
  end

  test "create_project without name param returns error" do
    headers = @admin_headers
    assert_no_difference "Instance.count" do
      post "#{MCP_PREFIX}/projects",
        params: {},
        headers: headers
    end
    # params.require(:name) raises ActionController::ParameterMissing -> 400
    assert_response :bad_request
  end
end
