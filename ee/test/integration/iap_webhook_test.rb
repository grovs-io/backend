require "test_helper"
require "sidekiq/testing"
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
    mock_service.expect(:handle_notification, true, [Hash, Project], expected_environment: Grovs::Apple::ENV_PRODUCTION)

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

class IapGoogleWebhookFlowTest < ActionDispatch::IntegrationTest
  include AuthTestHelper

  fixtures :instances, :projects

  setup do
    @instance = instances(:one) # revenue_collection_enabled: true
    @auth = { "Authorization" => "Bearer fake-google-jwt" }
  end

  def with_verified_token(&blk)
    GooglePubsubVerifier.stub(:verify, { "iss" => "https://accounts.google.com" }, &blk)
  end

  def rtdn_message(data)
    { message: { data: Base64.encode64(data.to_json) } }
  end

  test "Google RTDN with valid token stores webhook message and enqueues processing" do
    payload = { "version" => "1.0", "packageName" => "com.test.app",
                "subscriptionNotification" => { "notificationType" => 4 } }

    Sidekiq::Testing.fake! do
      ProcessGoogleNotificationJob.clear
      with_verified_token do
        assert_difference "IapWebhookMessage.count", 1 do
          post "#{IAP_PREFIX}/google/#{@instance.hashid}",
            params: rtdn_message(payload), as: :json, headers: @auth
        end
      end

      assert_response :ok
      assert_equal "ok", JSON.parse(response.body)["result"]
      msg = IapWebhookMessage.order(:id).last
      assert_equal Grovs::Webhooks::GOOGLE, msg.source
      assert_equal @instance.id, msg.instance_id
      assert_equal 1, ProcessGoogleNotificationJob.jobs.size
      job_args = ProcessGoogleNotificationJob.jobs.last["args"]
      assert_equal msg.id, job_args[0]
      assert_equal "com.test.app", job_args[1]["packageName"]
      assert_equal @instance.id, job_args[2]
    end
  end

  test "Google RTDN with missing message returns 400" do
    with_verified_token do
      post "#{IAP_PREFIX}/google/#{@instance.hashid}", params: {}, as: :json, headers: @auth
    end
    assert_response :bad_request
    assert_equal "Missing message", JSON.parse(response.body)["error"]
  end

  test "Google RTDN with message but no data returns 400" do
    with_verified_token do
      post "#{IAP_PREFIX}/google/#{@instance.hashid}",
        params: { message: { attributes: {} } }, as: :json, headers: @auth
    end
    assert_response :bad_request
    assert_equal "Missing data in message", JSON.parse(response.body)["error"]
  end

  test "Google RTDN with undecodable data returns 400 and does not enqueue" do
    Sidekiq::Testing.fake! do
      ProcessGoogleNotificationJob.clear
      with_verified_token do
        post "#{IAP_PREFIX}/google/#{@instance.hashid}",
          params: { message: { data: Base64.encode64("not json at all") } },
          as: :json, headers: @auth
      end
      assert_response :bad_request
      assert_equal "Invalid JSON", JSON.parse(response.body)["error"]
      assert_equal 0, ProcessGoogleNotificationJob.jobs.size
    end
  end

  test "Google RTDN with token that fails verification returns 403" do
    GooglePubsubVerifier.stub(:verify, nil) do
      post "#{IAP_PREFIX}/google/#{@instance.hashid}",
        params: rtdn_message({}), as: :json, headers: @auth
    end
    assert_response :forbidden
  end

  test "Apple webhook with malformed JSON body returns 400" do
    post "#{IAP_PREFIX}/apple/production/#{projects(:one).hashid}",
      env: { "RAW_POST_DATA" => "{not-json", "CONTENT_TYPE" => "application/json" }
    assert_response :bad_request
    assert_equal "invalid payload", JSON.parse(response.body)["error"]
  end

  test "Apple webhook returning unprocessed still acknowledges with 200" do
    mock_service = Minitest::Mock.new
    mock_service.expect(:handle_notification, false, [Hash, Project], expected_environment: Grovs::Apple::ENV_PRODUCTION)

    AppleIapService.stub(:new, mock_service) do
      post "#{IAP_PREFIX}/apple/production/#{projects(:one).hashid}",
        env: { "RAW_POST_DATA" => '{"signedPayload":"x"}', "CONTENT_TYPE" => "application/json" }
    end

    assert_response :ok
    assert_equal "unprocessed", JSON.parse(response.body)["result"]
  end
end
