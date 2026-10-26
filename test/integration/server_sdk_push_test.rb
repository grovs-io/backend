require "test_helper"
require "sidekiq/testing"
require_relative "auth_test_helper"

class ServerSdkPushTest < ActionDispatch::IntegrationTest
  include AuthTestHelper
  fixtures :instances, :projects, :visitors, :devices, :domains, :redirect_configs

  setup do
    @project = projects(:one)
    @headers = server_sdk_headers_for(@project)
    devices(:ios_device).update_columns(push_token: "tok")
    StripeSubscription.where(instance: @project.instance).update_all(active: false)
    clear_budgets
  end

  teardown { clear_budgets }

  def clear_budgets = REDIS.with { |c| c.del("push_api:segment:#{@project.id}", "push_api:recipients:#{@project.id}", "push_api:campaigns:#{@project.id}") }

  def body = { title: "Hi", body: "There", audience: { type: "identifiers", recipients: [visitors(:ios_visitor).sdk_identifier] } }

  def entitle = EnterpriseSubscription.create!(instance: @project.instance, active: true, start_date: 1.day.ago, end_date: 1.year.from_now, total_maus: 100)

  test "without an enterprise entitlement both endpoints are 403" do
    post "#{SDK_PREFIX}/server/push", params: body, headers: @headers, as: :json
    assert_response :forbidden
    get "#{SDK_PREFIX}/server/push/anything", headers: @headers
    assert_response :forbidden
  end

  test "an entitled instance creates and can read back the campaign; CE answers 404" do
    entitle
    unless defined?(PushCampaign)
      post "#{SDK_PREFIX}/server/push", params: body, headers: @headers, as: :json
      assert_response :not_found
      get "#{SDK_PREFIX}/server/push/x", headers: @headers
      assert_response :not_found
      return
    end
    apns = Rpush::Apnsp8::App.create!(name: "t-dev", environment: "development", apn_key: "k", apn_key_id: "id", team_id: "t", bundle_id: "b", connections: 1)
    Sidekiq::Testing.inline! do
      RpushService.stub(:app_for_platform, apns) { post "#{SDK_PREFIX}/server/push", params: body, headers: @headers, as: :json }
    end
    assert_response :accepted
    c = JSON.parse(response.body)["campaign"]
    assert_equal "api", c["source"]
    get "#{SDK_PREFIX}/server/push/#{c['id']}", headers: @headers
    assert_response :ok
    assert_equal 1, JSON.parse(response.body)["campaign"]["report"]["queued"]
    post "#{SDK_PREFIX}/server/push", params: body.merge(title: ""), headers: @headers, as: :json
    assert_response :unprocessable_entity
    get "#{SDK_PREFIX}/server/push/nope", headers: @headers
    assert_response :not_found
    other = PushCampaign.create!(project: projects(:two), name: "x", title: "t", body: "b", audience_type: "visitors", recipients: ["a"])
    get "#{SDK_PREFIX}/server/push/#{other.hashid}", headers: @headers
    assert_response :not_found, "another tenant's campaign must not be readable"
  ensure
    Rpush::Apnsp8::Notification.delete_all
    Rpush::Apnsp8::App.delete_all
  end

  test "budgets answer 429 with an error code" do
    skip "ee only" unless defined?(PushCampaign)
    entitle
    REDIS.with { |c| c.set("push_api:recipients:#{@project.id}", 100_000, ex: 60) }
    post "#{SDK_PREFIX}/server/push", params: body, headers: @headers, as: :json
    assert_response :too_many_requests
    assert_equal "rate_limited", JSON.parse(response.body)["error_code"]
  end
end
