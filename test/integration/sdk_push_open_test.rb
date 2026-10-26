require "test_helper"
require_relative "auth_test_helper"

class SdkPushOpenTest < ActionDispatch::IntegrationTest
  include AuthTestHelper
  fixtures :instances, :projects, :applications, :ios_configurations, :android_configurations, :devices, :visitors, :domains, :redirect_configs

  setup do
    @project = projects(:one)
    @visitor = visitors(:ios_visitor)
    @headers = sdk_headers_for(@project, @visitor)
  end

  test "push_open is a reserved event name, so the generic custom event endpoint refuses it" do
    assert_includes Grovs::Events::RESERVED_EVENT_NAMES, Grovs::Events::PUSH_OPEN
    post "#{SDK_PREFIX}/event/custom", params: { event_name: "push_open" }, headers: @headers, as: :json
    assert_response :bad_request
    assert_match(/reserved/, JSON.parse(response.body)["error"])
  end

  test "missing campaign id is 400" do
    post "#{SDK_PREFIX}/push_open", params: {}, headers: @headers, as: :json
    assert_response :bad_request
  end

  test "unknown campaign is 404" do
    post "#{SDK_PREFIX}/push_open", params: { campaign_id: "nope" }, headers: @headers, as: :json
    assert_response :not_found
  end

  test "a known campaign marks the delivery opened and logs the event" do
    skip "push campaigns are ee" unless defined?(PushCampaign)
    c = PushCampaign.create!(project: @project, name: "n", title: "t", body: "b", status: "sent", audience_type: "visitors", recipients: [@visitor.uuid])
    PushDelivery.create!(push_campaign: c, visitor: @visitor, device_id: devices(:ios_device).id, platform: "ios", status: "delivered")
    logged = []
    EventIngestionService.stub(:log_async, ->(*args, **kw) { logged << [args, kw] }) do
      post "#{SDK_PREFIX}/push_open", params: { campaign_id: c.hashid }, headers: @headers, as: :json
    end
    assert_response :ok
    assert_equal 1, c.reload.opened
    assert_equal Grovs::Events::PUSH_OPEN, logged.first[1][:event_name]
    assert_equal({ "campaign_id" => c.hashid }, logged.first[0][3])
    EventIngestionService.stub(:log_async, ->(*args, **kw) { logged << [args, kw] }) do
      post "#{SDK_PREFIX}/push_open", params: { campaign_id: c.hashid }, headers: @headers, as: :json
    end
    assert_response :ok
    assert_equal 1, logged.size, "a second tap is not a second analytics event"
  end
end
