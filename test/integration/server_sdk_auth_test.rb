require "test_helper"
require_relative "auth_test_helper"

class ServerSdkAuthTest < ActionDispatch::IntegrationTest
  include AuthTestHelper

  fixtures :instances, :projects, :domains, :redirect_configs, :links

  setup do
    @project = projects(:one)
    @link = links(:basic_link)
  end

  # --- Missing Headers ---

  test "missing PROJECT-KEY returns 400 with descriptive error" do
    post "#{SDK_PREFIX}/generate_link",
      headers: { "ENVIRONMENT" => "production", "Host" => sdk_host }
    assert_response :bad_request
    json = JSON.parse(response.body)
    assert_match(/PROJECT-KEY/i, json["error"])
    assert_not json.key?("link"), "error response must not contain link data"
  end

  test "missing ENVIRONMENT returns 400 with descriptive error" do
    post "#{SDK_PREFIX}/generate_link",
      headers: { "PROJECT-KEY" => @project.identifier, "Host" => sdk_host }
    assert_response :bad_request
    json = JSON.parse(response.body)
    assert_match(/ENVIRONMENT/i, json["error"])
  end

  # --- Invalid Environment ---

  test "invalid ENVIRONMENT value returns 400" do
    post "#{SDK_PREFIX}/generate_link",
      headers: { "PROJECT-KEY" => @project.identifier, "ENVIRONMENT" => "staging", "Host" => sdk_host }
    assert_response :bad_request
    json = JSON.parse(response.body)
    assert_match(/ENVIRONMENT/i, json["error"])
  end

  # --- Wrong Project Key ---

  test "wrong project key returns 403 with no project data" do
    post "#{SDK_PREFIX}/generate_link",
      headers: { "PROJECT-KEY" => "nonexistent-key", "ENVIRONMENT" => "production", "Host" => sdk_host }
    assert_response :forbidden
    json = JSON.parse(response.body)
    assert_equal "Invalid credentials", json["error"]
    assert_not json.key?("link"), "403 must not contain link data"
  end

  # --- Valid Production Auth ---

  test "valid production auth generates and persists link" do
    headers = server_sdk_headers_for(@project)
    assert_difference "Link.count", 1 do
      post "#{SDK_PREFIX}/generate_link",
        params: { title: "API Link" },
        headers: headers
    end
    assert_response :ok
    json = JSON.parse(response.body)
    assert json["link"].present?, "response must contain link path"

    # Verify the link actually exists in the DB
    created_link = Link.order(:created_at).last
    assert_equal "API Link", created_link.title
    assert created_link.sdk_generated, "link must be marked as sdk_generated"
  end

  # --- Valid Test Environment ---

  test "wrong api_key with test environment returns 403" do
    headers = {
      "PROJECT-KEY" => "nonexistent-api-key",
      "ENVIRONMENT" => "test",
      "Host" => sdk_host
    }
    assert_no_difference "Link.count" do
      post "#{SDK_PREFIX}/generate_link",
        params: { title: "Test Link" },
        headers: headers
    end
    assert_response :forbidden
  end

  # --- Link Details ---

  test "link details returns correct link data" do
    headers = server_sdk_headers_for(@project)
    get "#{SDK_PREFIX}/link/#{@link.path}", headers: headers
    assert_response :ok
    json = JSON.parse(response.body)
    assert_equal @link.title, json["link"]["title"]
    assert_equal @link.subtitle, json["link"]["subtitle"]
    assert_equal @link.path, json["link"]["path"]
  end

  test "link details for nonexistent path returns 404 with error" do
    headers = server_sdk_headers_for(@project)
    get "#{SDK_PREFIX}/link/nonexistent-path-xyz", headers: headers
    assert_response :not_found
    json = JSON.parse(response.body)
    assert_equal "Link not found", json["error"]
    assert_not json.key?("link"), "404 must not contain link data"
  end
end
