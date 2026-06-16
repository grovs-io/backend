require "test_helper"
require_relative "auth_test_helper"

class SdkEventsTest < ActionDispatch::IntegrationTest
  include AuthTestHelper

  fixtures :instances, :projects, :applications, :ios_configurations,
           :android_configurations, :devices, :visitors, :domains,
           :redirect_configs, :links

  setup do
    @project = projects(:one)
    @visitor = visitors(:ios_visitor)
    @link = links(:basic_link)
    @headers = sdk_headers_for(@project, @visitor, platform: "ios")
    REDIS.del("events:pending")
  end

  def last_queued_event
    raw = REDIS.with { |c| c.lindex("events:pending", 0) }
    raw && JSON.parse(raw)
  end

  test "event with link url resolves the link and queues with link_id" do
    url = "https://#{@link.domain.subdomain}.#{@link.domain.domain}/#{@link.path}"
    post "#{SDK_PREFIX}/event", params: { event: "open", link: url }, headers: @headers

    assert_response :ok
    payload = last_queued_event
    assert_equal "open", payload["type"]
    assert_equal @link.id, payload["link_id"]
  end

  test "event with path resolves the link for the project" do
    post "#{SDK_PREFIX}/event", params: { event: "open", path: @link.path }, headers: @headers

    assert_response :ok
    assert_equal @link.id, last_queued_event["link_id"]
  end

  test "event with a foreign project's link url queues without link_id" do
    other = links(:second_link)
    url = "https://#{other.domain.subdomain}.#{other.domain.domain}/#{other.path}"
    post "#{SDK_PREFIX}/event", params: { event: "open", link: url }, headers: @headers

    assert_response :ok
    assert_nil last_queued_event["link_id"], "cross-tenant link must not be attributed"
  end

  test "event with unresolvable link still queues without link_id" do
    post "#{SDK_PREFIX}/event",
      params: { event: "open", link: "https://nope.example.com/missing" }, headers: @headers

    assert_response :ok
    assert_nil last_queued_event["link_id"]
  end

  test "link resolution failure does not lose the event" do
    LinksService.stub(:link_for_url, ->(*) { raise "boom" }) do
      post "#{SDK_PREFIX}/event",
        params: { event: "open", link: "https://x.example.com/p" }, headers: @headers
    end

    assert_response :ok
    assert_equal "open", last_queued_event["type"]
  end

  test "valid created_at is honored in the queued payload" do
    ts = 2.days.ago.change(usec: 0)
    post "#{SDK_PREFIX}/event",
      params: { event: "app_open", created_at: ts.iso8601 }, headers: @headers

    assert_response :ok
    assert_in_delta ts.to_f, Time.parse(last_queued_event["created_at"]).to_f, 1.0
  end

  test "unparseable created_at falls back instead of failing" do
    post "#{SDK_PREFIX}/event",
      params: { event: "app_open", created_at: "not-a-date" }, headers: @headers

    assert_response :ok
    payload = last_queued_event
    assert_in_delta Time.current.to_f, Time.parse(payload["created_at"]).to_f, 5.0
  end

  test "event with engagement_time queues it" do
    post "#{SDK_PREFIX}/event",
      params: { event: "time_spent", engagement_time: 42 }, headers: @headers

    assert_response :ok
    assert_equal "42", last_queued_event["engagement_time"].to_s
  end
end
