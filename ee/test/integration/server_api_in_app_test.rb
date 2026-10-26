require "test_helper"
require "sidekiq/testing"
require_relative "../../../test/integration/auth_test_helper"

class ServerApiInAppTest < ActionDispatch::IntegrationTest
  include AuthTestHelper
  include AuditTestHelper
  include ClickhouseTestHelper
  include InAppFixtures

  fixtures :instances, :users, :instance_roles, :projects, :visitors, :devices

  BASE = "#{SDK_PREFIX}/server/in_app_campaigns".freeze
  IMAGE = "https://img.example.com/welcome.png".freeze

  setup do
    skip_unless_clickhouse!
    @project = projects(:one)
    @instance = @project.instance
    entitle!(@instance)
    @headers = server_sdk_headers_for(@project)
    clear_in_app_stamps(@project)
  end

  def body = response.parsed_body
  def valid = { name: "Welcome", content: CONTENT.merge("image" => { "portrait" => IMAGE, "landscape" => nil }), triggers: TRIGGERS }

  def created
    post BASE, params: valid, headers: @headers, as: :json
    assert_response :created
    body["in_app_campaign"]["id"]
  end

  test "create keeps an https image URL, and is audited as the api key with no creator" do
    id = created
    assert_equal IMAGE, body.dig("in_app_campaign", "content", "image", "portrait")
    assert_equal "draft", body["in_app_campaign"]["status"]
    campaign = InAppCampaign.find_by_hashid(id)
    assert_nil campaign.created_by_id
    event = AuditEvent.find_by(instance_id: @instance.id, action: "in_app_campaign.created")
    assert_equal "api_key", event.actor["type"]
  end

  test "an invalid definition is 422 and nothing is saved" do
    post BASE, params: valid.merge(content: "text"), headers: @headers, as: :json
    assert_response :unprocessable_entity
    post BASE, params: valid.merge(triggers: { type: "event" }), headers: @headers, as: :json
    assert_response :unprocessable_entity
    assert_equal 0, InAppCampaign.count
  end

  test "index, show, update and destroy a draft" do
    id = created
    get BASE, headers: @headers
    assert_response :ok
    assert_equal [id], body["in_app_campaigns"].map { |c| c["id"] }

    get "#{BASE}/#{id}", headers: @headers
    assert_response :ok
    assert_equal "Welcome", body["in_app_campaign"]["name"]

    patch "#{BASE}/#{id}", params: { name: "Renamed" }, headers: @headers, as: :json
    assert_response :ok
    assert_equal "Renamed", body["in_app_campaign"]["name"]

    delete "#{BASE}/#{id}", headers: @headers
    assert_response :ok
    assert_nil InAppCampaign.find_by_hashid(id)
    assert AuditEvent.where(instance_id: @instance.id, action: %w[in_app_campaign.updated in_app_campaign.deleted]).all? { |e| e.actor["type"] == "api_key" }
  end

  test "launch, pause, resume and end; a launched campaign cannot be deleted" do
    id = created
    { "launch" => :accepted, "pause" => :ok, "resume" => :ok }.each do |step, code|
      post "#{BASE}/#{id}/#{step}", headers: @headers, as: :json
      assert_response code, step
    end
    delete "#{BASE}/#{id}", headers: @headers
    assert_response :conflict
    post "#{BASE}/#{id}/end", headers: @headers, as: :json
    assert_response :ok
    assert_equal "ended", InAppCampaign.find_by_hashid(id).status
    %w[launched paused resumed ended].each do |action|
      assert_equal "api_key", AuditEvent.find_by(instance_id: @instance.id, action: "in_app_campaign.#{action}").actor["type"], action
    end
  end

  test "test shows the message to one person by identifier" do
    visitors(:ios_visitor).update_columns(sdk_identifier: "ana@example.com")
    id = created
    post "#{BASE}/#{id}/test", params: { identifier: "ana@example.com" }, headers: @headers, as: :json
    assert_response :accepted
    assert_equal 1, body["devices"]
    post "#{BASE}/#{id}/test", params: { identifier: "nobody" }, headers: @headers, as: :json
    assert_response :unprocessable_entity
  end

  test "report reads ClickHouse" do
    campaign = live_in_app_campaign(@project)
    day = Time.current.utc.beginning_of_day + 1.hour
    insert_ch_events([{ project_id: @project.id, event_type: "custom", event_name: "in_app_viewed", visitor_id: 1, platform: "ios",
                        created_at: day.strftime("%Y-%m-%d %H:%M:%S.%L"), properties: { campaign_id: campaign.hashid } }])
    get "#{BASE}/#{campaign.hashid}/report", headers: @headers
    assert_response :ok
    assert_equal 1, body["report"]["totals"]["views"]
  end

  test "another environment's or instance's key cannot see the campaign" do
    id = created
    get "#{BASE}/#{id}", headers: server_sdk_headers_for(@project, environment: "test")
    assert_response :not_found
    entitle!(projects(:two).instance)
    get "#{BASE}/#{id}", headers: server_sdk_headers_for(projects(:two))
    assert_response :not_found
  end

  test "answers, comments, media, images, duplicate and audience updates are not routed" do
    id = created
    get "#{BASE}/#{id}/answers", headers: @headers
    assert_response :not_found
    get "#{BASE}/#{id}/comments", headers: @headers
    assert_response :not_found
    get "#{BASE}/#{id}/media", headers: @headers
    assert_response :not_found
    post "#{BASE}/#{id}/images/portrait", headers: @headers
    assert_response :not_found
    post "#{BASE}/#{id}/duplicate", headers: @headers, as: :json
    assert_response :not_found
    post "#{BASE}/#{id}/update_audience", headers: @headers, as: :json
    assert_response :not_found
    assert_equal 1, InAppCampaign.count
  end
end
