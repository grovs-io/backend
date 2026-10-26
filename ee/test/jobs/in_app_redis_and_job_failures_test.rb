require "test_helper"
require "sidekiq/testing"

class InAppRedisAndJobFailuresTest < ActiveSupport::TestCase
  include InAppFixtures
  include ConstStubHelper
  fixtures :instances, :projects, :visitors, :devices

  # Each call to `with` takes the next answer: :real uses Redis, anything else raises as a lost connection does.
  class ScriptedRedis
    def initialize(real, *script)
      @real = real
      @script = script
    end

    def with(&block) = @script.shift == :real ? @real.with(&block) : raise(Redis::CannotConnectError, "down")
  end

  setup do
    @project = projects(:one)
    @ana = visitors(:ios_visitor)
    clear_in_app_stamps(@project)
    Sidekiq::Testing.fake!
    Sidekiq::Worker.clear_all
  end

  teardown { Sidekiq::Testing.disable! }

  def redis(*script, &block) = with_const(Object, :REDIS, ScriptedRedis.new(REDIS, *script), &block)
  def campaigns_stamp = REDIS.with { |c| c.get("in_app:campaigns:#{@project.id}") }

  def segment_campaign
    segment = Segment.create!(project: @project, name: "S#{SecureRandom.hex(2)}", definition: SEGMENT_DEFINITION)
    campaign = in_app_campaign(@project, audience_type: "segment", segment: segment)
    campaign.launch!
    campaign
  end

  test "a pause commits while Redis is down, and the next tick sends devices to sync" do
    campaign = live_in_app_campaign(@project)
    before = campaigns_stamp
    travel(1.second) { redis { assert campaign.transition!(from: %w[live], to: "paused") } }
    assert_equal "paused", campaign.reload.status
    assert_equal before, campaigns_stamp, "the stamp Redis could not take"

    travel(2.seconds) { InAppCampaignTickJob.new.perform }
    assert_operator campaigns_stamp.to_i, :>=, (campaign.updated_at.to_f * 1000).to_i
  end

  test "the tick with Redis down still ends what has run out, leaving the stamp to a later tick" do
    due = live_in_app_campaign(@project, end_at: 1.hour.from_now)
    travel(2.hours) do
      live_in_app_campaign(@project)
      before = campaigns_stamp
      redis { assert_nothing_raised { InAppCampaignTickJob.new.perform } }
      assert_equal before, campaigns_stamp
    end
    assert_equal "ended", due.reload.status
  end

  test "a settings change Redis failed to stamp is healed by the tick, even with no campaign changed" do
    live_in_app_campaign(@project).update_columns(updated_at: 2.hours.ago)
    setting = InAppSetting.create!(project: @project, session_cap: 3)
    REDIS.with { |c| c.set("in_app:campaigns:#{@project.id}", "1") }
    InAppCampaignTickJob.new.perform
    assert_operator campaigns_stamp.to_i, :>=, (setting.updated_at.to_f * 1000).to_i
  end

  test "with Redis down a sync still serves the campaigns, without stamps or test messages" do
    campaign = live_in_app_campaign(@project)
    body = redis { InAppSync.call(project: @project, visitor: @ana, held: nil) }
    assert_equal [campaign.hashid], body["campaigns"].pluck("id")
    assert_equal [], body["test_messages"]
    assert_not body.key?("campaigns_changed_at"), "no stamp a device would keep and compare"
  end

  test "a test message whose user stamp Redis lost is still handed over, once" do
    @ana.update_columns(sdk_identifier: "ana")
    campaign = in_app_campaign(@project)
    assert_equal 1, redis(:real) { InAppTests.deliver(campaign, "ana") }
    assert_equal InAppStamps::NEVER, InAppStamps.user(@ana.id)
    assert_equal [campaign.definition["content"]], InAppTests.take(@ana.id).map { |d| d["content"] }
    assert_equal [], InAppTests.take(@ana.id)
  end

  test "a test that cannot be stored is refused with a retry message; a stored one that is corrupt is dropped" do
    @ana.update_columns(sdk_identifier: "ana")
    campaign = in_app_campaign(@project)
    error = assert_raises(InAppCampaign::Refused) { redis { InAppTests.deliver(campaign, "ana") } }
    assert_equal "The test could not be sent right now; try again in a moment", error.message
    assert_nil REDIS.with { |c| c.get(InAppTests.key(@ana.id)) }

    REDIS.with { |c| c.set(InAppTests.key(@ana.id), "{broken", ex: 60) }
    assert_equal [], InAppTests.take(@ana.id)
    assert_nil REDIS.with { |c| c.get(InAppTests.key(@ana.id)) }, "taken, so it is not retried at every sync"
  end

  test "a population whose retries ran out sends the campaign back to draft; one already live is left alone" do
    preparing = segment_campaign
    live = segment_campaign
    live.update_columns(status: "live")
    exhausted = InAppMembershipPopulateJob.sidekiq_retries_exhausted_block
    [preparing, live].each { |c| exhausted.call({ "args" => [c.id] }, RuntimeError.new("boom")) }
    exhausted.call({ "args" => [0] }, RuntimeError.new("boom"))
    exhausted.call({}, RuntimeError.new("boom"))

    preparing.reload
    assert_equal ["draft", "audience_error", nil, nil], [preparing.status, preparing.failure_reason, preparing.launched_at, preparing.segment_key]
    assert_equal ["live", nil], [live.reload.status, live.failure_reason]
  end

  test "an audience update that can never succeed is dropped, counted, and leaves the campaign on its old audience" do
    campaign = segment_campaign
    campaign.transition!(from: %w[preparing], to: "live")
    old = campaign.segment_key
    campaign.segment.update_columns(definition_hash: "d" * 64)
    counted = []
    Grovs::Metrics.stub(:increment, ->(name, tags: {}) { counted << [name, tags] }) do
      InAppMemberships.stub(:refresh, ->(*, **) { raise Segments::InvalidDefinition, "bad" }) do
        assert_nothing_raised { InAppAudienceUpdateJob.new.perform(campaign.id) }
      end
    end
    assert_equal [["in_app.audience_update_refused", { reason: "Segments::InvalidDefinition" }]], counted
    assert_equal [old, "live"], [campaign.reload.segment_key, campaign.status]
    assert_empty InAppMembershipCleanupJob.jobs
  end
end
