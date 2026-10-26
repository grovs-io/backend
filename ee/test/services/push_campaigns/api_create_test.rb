require "test_helper"
require "sidekiq/testing"

class PushCampaigns::ApiCreateTest < ActiveSupport::TestCase
  fixtures :instances, :projects, :visitors, :devices, :domains, :redirect_configs, :links

  setup do
    devices(:ios_device).update_columns(push_token: "tok")
    @project = projects(:one)
    @apns = Rpush::Apnsp8::App.create!(name: "t-dev", environment: "development", apn_key: "k", apn_key_id: "id", team_id: "t", bundle_id: "b", connections: 1)
    clear_budgets
  end

  teardown do
    Rpush::Apnsp8::Notification.delete_all
    Rpush::Apnsp8::App.delete_all
    clear_budgets
  end

  def clear_budgets = REDIS.with { |c| c.del("push_api:segment:#{@project.id}", "push_api:recipients:#{@project.id}", "push_api:campaigns:#{@project.id}") }

  def params(**extra)
    { title: "Hi", body: "There", audience: { type: "identifiers", recipients: [visitors(:ios_visitor).sdk_identifier] } }.merge(extra)
  end

  test "a send is created as evaluating, audited as created and scheduled, and handed to the evaluate job" do
    EnterpriseSubscription.create!(instance: @project.instance, active: true, start_date: 1.day.ago, end_date: 1.year.from_now, total_maus: 100)
    Sidekiq::Testing.fake! do
      PushCampaignEvaluateJob.clear
      c = PushCampaigns::ApiCreate.call(project: @project, params: params)
      assert_equal %w[api evaluating], [c.source, c.reload.status]
      assert_equal [[c.id]], PushCampaignEvaluateJob.jobs.map { |j| j["args"] }
      assert_equal %w[push_campaign.created push_campaign.scheduled], AuditEvent.where("target->>'id' = ?", c.id.to_s).order(:id).pluck(:action)
    end
  end

  test "the evaluate job then delivers it end to end" do
    Sidekiq::Testing.inline! do
      c = RpushService.stub(:app_for_platform, @apns) { PushCampaigns::ApiCreate.call(project: @project, params: params) }
      assert_equal "sent", c.reload.status
      assert_equal 1, Rpush::Apnsp8::Notification.count
    end
  end

  test "invalid payload raises Invalid with the messages" do
    e = assert_raises(PushCampaign::Invalid) { PushCampaigns::ApiCreate.call(project: @project, params: params(title: "")) }
    assert_match(/Title/, e.message)
    [params(scheduled_at: "yesterday-ish"), params(link_id: "nope"), params(data: "text"),
     params(audience: { type: "segment", segment_id: "nope" })].each do |bad|
      assert_raises(PushCampaign::Invalid) { PushCampaigns::ApiCreate.call(project: @project, params: bad) }
    end
  end

  test "a refused schedule leaves no draft behind and charges no budget" do
    assert_no_difference("PushCampaign.count") do
      assert_raises(PushCampaign::Invalid) { PushCampaigns::ApiCreate.call(project: @project, params: params(scheduled_at: 1.hour.ago.iso8601)) }
    end
    assert_nil REDIS.with { |c| c.get("push_api:recipients:#{@project.id}") }
    assert_nil REDIS.with { |c| c.get("push_api:campaigns:#{@project.id}") }
  end

  test "segment and recipients budgets are enforced per project and a refusal does not burn the window" do
    REDIS.with { |c| c.set("push_api:recipients:#{@project.id}", 100_000, ex: 60) }
    assert_raises(PushCampaign::RateLimited) { PushCampaigns::ApiCreate.call(project: @project, params: params) }
    assert_equal 100_000, REDIS.with { |c| c.get("push_api:recipients:#{@project.id}") }.to_i
    assert_nil REDIS.with { |c| c.get("push_api:campaigns:#{@project.id}") }, "a refused recipients budget charges no campaign"
    clear_budgets
    REDIS.with { |c| c.set("push_api:segment:#{@project.id}", 10, ex: 60) }
    seg = Segment.create!(project: @project, name: "S", definition: PushCampaignFixtures::SEGMENT_DEFINITION)
    assert_raises(PushCampaign::RateLimited) do
      PushCampaigns::ApiCreate.call(project: @project, params: params(audience: { type: "segment", segment_id: seg.hashid }))
    end
    clear_budgets
    REDIS.with { |c| c.set("push_api:campaigns:#{@project.id}", 600, ex: 60) }
    assert_raises(PushCampaign::RateLimited) { PushCampaigns::ApiCreate.call(project: @project, params: params) }
    assert_equal 0, REDIS.with { |c| c.get("push_api:recipients:#{@project.id}") }.to_i, "a campaigns refusal refunds the recipients charge"
  end

  test "a budget key always carries a TTL, even when it expired between calls or a refund outlived it" do
    key = "push_api:recipients:#{@project.id}"
    Sidekiq::Testing.fake! do
      REDIS.with { |c| c.set(key, 5) }
      PushCampaigns::ApiCreate.call(project: @project, params: params)
      assert_operator REDIS.with { |c| c.ttl(key) }, :>, 0, "a key left without TTL by an old race gets one back"

      clear_budgets
      PushCampaigns::ApiCreate.new(@project, {}).send(:refund, key, 1)
      assert_nil REDIS.with { |c| c.get(key) }, "a refund after the window closed does not recreate the key without a TTL"

      PushCampaigns::ApiCreate.call(project: @project, params: params)
      assert_operator REDIS.with { |c| c.ttl(key) }, :>, 0
    end
  end

  test "local_time without scheduled_at is refused, not sent now" do
    assert_raises(PushCampaign::Invalid) { PushCampaigns::ApiCreate.call(project: @project, params: params(local_time: true)) }
  end

  test "scheduled_at schedules instead of sending" do
    c = PushCampaigns::ApiCreate.call(project: @project, params: params(scheduled_at: 1.hour.from_now.iso8601))
    assert_equal "scheduled", c.status
  end

  test "link_id is the numeric link id and must belong to the project" do
    link = links(:basic_link)
    Sidekiq::Testing.fake! do
      c = PushCampaigns::ApiCreate.call(project: @project, params: params(link_id: link.id))
      assert_equal link.id, c.link_id
      assert_equal link.id, c.api_json["link_id"]
    end
    assert_raises(PushCampaign::Invalid) { PushCampaigns::ApiCreate.call(project: @project, params: params(link_id: links(:second_link).id)) }
  end
end
