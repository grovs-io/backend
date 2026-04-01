require "test_helper"
require_relative "../../../test/integration/auth_test_helper"

class IapWebhookTest < ActionDispatch::IntegrationTest
  include AuthTestHelper

  fixtures :instances, :projects

  setup do
    @project = projects(:one)
    @instance_one = instances(:one)
    @instance_two = instances(:two) # revenue_collection_enabled: false
  end

  # --- Apple: Invalid Project Hashid ---

  test "Apple webhook with invalid project hashid returns 403" do
    post "#{IAP_PREFIX}/apple/production/nonexistent_hashid",
      env: { "RAW_POST_DATA" => '{"signedPayload":"fake"}', "CONTENT_TYPE" => "application/json" }
    assert_response :forbidden
    json = JSON.parse(response.body)
    assert_equal "Forbidden", json["error"]
  end

  # --- Apple: Revenue Collection Disabled ---

  test "Apple webhook with revenue collection disabled returns ok with skip message" do
    project_two = projects(:two)
    post "#{IAP_PREFIX}/apple/production/#{project_two.hashid}",
      env: { "RAW_POST_DATA" => '{"signedPayload":"fake"}', "CONTENT_TYPE" => "application/json" }
    assert_response :ok
    json = JSON.parse(response.body)
    assert_equal "revenue collection not enabled", json["result"]
  end

  # --- Apple: Valid Hashid, Revenue Enabled ---

  test "Apple webhook with valid hashid and revenue enabled processes notification" do
    mock_service = Minitest::Mock.new
    mock_service.expect(:handle_notification, true, [Hash, Project])

    AppleIapService.stub(:new, mock_service) do
      post "#{IAP_PREFIX}/apple/production/#{@project.hashid}",
        env: { "RAW_POST_DATA" => '{"signedPayload":"fake"}', "CONTENT_TYPE" => "application/json" }
    end

    assert_response :ok
    json = JSON.parse(response.body)
    assert_equal "ok", json["result"]
    mock_service.verify
  end

  # --- Google: Missing Authorization Header ---

  test "Google webhook without Authorization header returns 403" do
    post "#{IAP_PREFIX}/google/#{@instance_one.hashid}",
      params: { message: { data: Base64.encode64("{}") } }.to_json,
      headers: { "Content-Type" => "application/json" }
    assert_response :forbidden
    json = JSON.parse(response.body)
    assert_equal "Missing authorization", json["error"]
  end

  # --- Google: Invalid Instance Hashid ---

  test "Google webhook with invalid instance hashid returns 403" do
    post "#{IAP_PREFIX}/google/nonexistent_hashid",
      params: { message: { data: Base64.encode64("{}") } }.to_json,
      headers: { "Content-Type" => "application/json", "Authorization" => "Bearer fake_token" }
    assert_response :forbidden
    json = JSON.parse(response.body)
    assert_equal "Forbidden", json["error"]
  end

  # --- Google: Revenue Collection Disabled ---

  test "Google webhook with revenue collection disabled returns ok with skip" do
    GooglePubsubVerifier.stub(:verify, { "email" => "test@gserviceaccount.com" }) do
      post "#{IAP_PREFIX}/google/#{@instance_two.hashid}",
        params: { message: { data: Base64.encode64("{}") } }.to_json,
        headers: { "Content-Type" => "application/json", "Authorization" => "Bearer fake_token" }
    end
    assert_response :ok
    json = JSON.parse(response.body)
    assert_equal "revenue collection not enabled", json["result"]
  end
end
