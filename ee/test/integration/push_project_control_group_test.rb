require "test_helper"
require "sidekiq/testing"
require_relative "../../../test/integration/auth_test_helper"

class PushProjectControlGroupTest < ActionDispatch::IntegrationTest
  include AuthTestHelper
  include AuditTestHelper
  fixtures :instances, :users, :instance_roles, :projects, :visitors, :devices, :domains, :redirect_configs

  CONTROL = 20

  setup do
    @project = projects(:one)
    entitle!(@project.instance)
    StripeSubscription.where(instance: @project.instance).update_all(active: false)
    devices(:ios_device).update_columns(push_token: "tok")
    InAppSetting.create!(project: @project, control_group: CONTROL)
    @people = []
    @people << Visitor.create!(project: @project, device: devices(:ios_device)) until split_ok?
    clear_queue
    clear_budgets
  end

  teardown { clear_budgets }

  def in_control?(visitor) = Experiments::Bucket.of(@project.hashid, visitor.id) < CONTROL
  def split_ok? = @people.count { |v| in_control?(v) } >= 3 && @people.count { |v| !in_control?(v) } >= 3
  def control_ids = @people.select { |v| in_control?(v) }.map(&:id).sort
  def clear_queue = REDIS.with { |c| c.del(BatchEventProcessorJob::REDIS_KEY) }
  def clear_budgets = REDIS.with { |c| c.del("push_api:recipients:#{@project.id}", "push_api:campaigns:#{@project.id}") }

  def held_events
    REDIS.with { |c| c.lrange(BatchEventProcessorJob::REDIS_KEY, 0, -1) }.map { |raw| JSON.parse(raw) }.select { |e| e["event_name"] == "push_held" }
  end

  def evaluate!(hashid)
    campaign = PushCampaign.find_by_hashid(hashid)
    Sidekiq::Testing.fake! { PushCampaignEvaluateJob.new.perform(campaign.id) }
    campaign.reload
  end

  test "a dashboard campaign keeps the project control group back, and held plus targeted is the whole audience" do
    admin = doorkeeper_headers_for(users(:admin_user))
    base = "#{API_PREFIX}/projects/#{@project.id}/push_campaigns"
    post base, params: { name: "n", title: "t", body: "b", audience: { type: "visitors", recipients: @people.map(&:uuid) } }, headers: admin, as: :json
    assert_response :created
    id = JSON.parse(response.body)["push_campaign"]["id"]
    Sidekiq::Testing.fake! { post "#{base}/#{id}/send", headers: admin, as: :json }
    assert_response :accepted

    c = evaluate!(id)
    assert_equal "dashboard", c.source
    assert_equal control_ids, c.deliveries.where(status: "held").pluck(:visitor_id).sort
    assert_equal [nil], c.deliveries.where(status: "held").distinct.pluck(:variant)
    assert_equal [control_ids.size, @people.size - control_ids.size], [c.held, c.targeted]
    assert_equal @people.size, c.held + c.targeted
    assert_equal [{ "campaign_id" => c.hashid, "scope" => "project" }], held_events.map { |e| e["data"] }.uniq
    assert_equal control_ids.size, held_events.size

    get "#{base}/#{id}", headers: admin
    assert_equal control_ids.size, JSON.parse(response.body)["push_campaign"]["report"]["held"]
  end

  test "an API push to the same people is never held by the project control group" do
    post "#{SDK_PREFIX}/server/push", params: { title: "t", body: "b", audience: { type: "visitors", recipients: @people.map(&:uuid) } },
                                      headers: server_sdk_headers_for(@project), as: :json
    assert_response :accepted
    c = evaluate!(JSON.parse(response.body)["campaign"]["id"])
    assert_equal "api", c.source
    assert_equal [0, @people.size], [c.held, c.targeted]
    assert_equal ["pending"], c.deliveries.distinct.pluck(:status)
    assert_empty held_events

    get "#{SDK_PREFIX}/server/push/#{c.hashid}", headers: server_sdk_headers_for(@project)
    assert_equal 0, JSON.parse(response.body)["campaign"]["report"]["held"]
  end

  test "a journey push is never held by the project control group either" do
    c = PushCampaign.create!(project: @project, name: "n", title: "t", body: "b", source: "journey", audience_type: "visitors",
                             recipients: @people.map(&:uuid))
    out = PushCampaigns::Audience.freeze!(c)
    assert_equal [0, @people.size], out.values_at(:held, :targeted)
    assert_empty held_events
  end

  test "without a project control group a dashboard campaign holds nobody" do
    InAppSetting.for(@project).update!(control_group: 0)
    c = PushCampaign.create!(project: @project, name: "n", title: "t", body: "b", audience_type: "visitors", recipients: @people.map(&:uuid))
    assert_equal "dashboard", c.source
    assert_equal [0, @people.size], PushCampaigns::Audience.freeze!(c).values_at(:held, :targeted)
  end
end
