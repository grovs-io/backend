require "test_helper"
require_relative "auth_test_helper"

# Every released SDK still asks the removed inbox: it needs exactly 200, a JSON object, and the key present.
class SdkNotificationsTest < ActionDispatch::IntegrationTest
  include AuthTestHelper

  fixtures :instances, :projects, :applications, :ios_configurations, :android_configurations, :devices, :visitors, :domains,
           :redirect_configs

  LISTS = { "notifications_for_device" => :post, "notifications_to_display_automatically" => :get }.freeze

  setup do
    @project = projects(:one)
    @visitor = visitors(:ios_visitor)
    @headers = sdk_headers_for(@project, @visitor, platform: "ios")
  end

  def ask(verb, path, params = {}, headers: @headers)
    public_send(verb, "#{SDK_PREFIX}/#{path}", params: params, headers: headers)
  end

  def assert_exact(body)
    assert_equal 200, response.status
    assert_equal "application/json", response.media_type
    assert_equal body, JSON.parse(response.body)
  end

  LISTS.each do |path, verb|
    test "#{path} answers 200 with an empty list, whatever it is sent" do
      [{}, { page: 1 }, { page: 9_999 }, { page: "x" }].each do |params|
        ask(verb, path, params)
        assert_exact("notifications" => [])
      end
    end
  end

  test "the number of unread messages is 0, a JSON integer" do
    ask(:get, "number_of_unread_notifications")
    assert_exact("number_of_unread_notifications" => 0)
    assert_includes response.body, ":0"
  end

  test "marking a message as read answers 200 for any id, a missing one included" do
    [{ id: 1 }, { id: "abc" }, { id: 0 }, {}].each do |params|
      ask(:post, "mark_notification_as_read", params)
      assert_exact("message" => "Marked as read")
    end
  end

  test "every platform an app may run on gets the same answers" do
    { "ios" => visitors(:ios_visitor), "android" => visitors(:android_visitor) }.each do |platform, visitor|
      headers = sdk_headers_for(@project, visitor, platform: platform)
      ask(:get, "notifications_to_display_automatically", headers: headers)
      assert_exact("notifications" => [])
    end
  end

  test "a JSON body is accepted as a form body is" do
    post "#{SDK_PREFIX}/notifications_for_device", params: { page: 2 }, headers: @headers, as: :json
    assert_exact("notifications" => [])
  end

  test "no answer reads the legacy tables, which are to be dropped" do
    touched = []
    watch = ->(*, payload) { touched << payload[:sql] if payload[:sql].match?(/notification/i) }
    ActiveSupport::Notifications.subscribed(watch, "sql.active_record") do
      LISTS.each { |path, verb| ask(verb, path, { page: 1 }) }
      ask(:get, "number_of_unread_notifications")
      ask(:post, "mark_notification_as_read", { id: 1 })
    end
    assert_empty touched
  end

  test "without SDK headers the answer is still a JSON object, never a page" do
    (LISTS.to_a + [["number_of_unread_notifications", :get], ["mark_notification_as_read", :post]]).each do |path, verb|
      ask(verb, path, headers: { "Host" => sdk_host })
      assert_response :forbidden
      assert_kind_of Hash, JSON.parse(response.body)
      assert_not JSON.parse(response.body).key?("notifications")
    end
  end

  test "creating a visitor no longer touches the legacy tables" do
    touched = []
    watch = ->(*, payload) { touched << payload[:sql] if payload[:sql].match?(/notification/i) }
    ActiveSupport::Notifications.subscribed(watch, "sql.active_record") do
      Visitor.create!(project: projects(:two), device: devices(:ios_device), web_visitor: false)
    end
    assert_empty touched
  end

  # Old Android sends the push token through a loop that retries for ever on anything but 200 with a body.
  test "visitor attributes still accept a push token and answer 200 with a JSON object" do
    post "#{SDK_PREFIX}/visitor_attributes", params: { push_token: "token-1" }, headers: @headers, as: :json
    assert_equal 200, response.status
    assert_kind_of Hash, JSON.parse(response.body)
  end
  test "a message job queued before the inbox was removed ends quietly" do
    assert_nil SendMessagesJob.new.perform(123)
  end

end
