require "test_helper"
require "sidekiq/testing"

class PushCampaignEvaluateJobTest < ActiveSupport::TestCase
  fixtures :instances, :projects, :visitors, :devices

  setup do
    devices(:ios_device).update_columns(push_token: "tok")
    @campaign = PushCampaign.create!(project: projects(:one), name: "n", title: "t", body: "b", status: "evaluating",
                                     audience_type: "visitors", recipients: [visitors(:ios_visitor).uuid, "nope"])
  end

  test "freezes the audience, stores counters and moves to sending with deliver jobs" do
    Sidekiq::Testing.fake! do
      PushCampaignDeliverJob.clear
      PushCampaignEvaluateJob.new.perform(@campaign.id)
      slots = Array.new(PushCampaignEvaluateJob::PARALLELISM) { |slot| [@campaign.id, slot] }
      assert_equal slots, PushCampaignDeliverJob.jobs.map { |j| j["args"] }
    end
    @campaign.reload
    assert_equal "sending", @campaign.status
    assert_equal [1, 0, 1], [@campaign.targeted, @campaign.no_channel, @campaign.not_found]
    assert @campaign.evaluated_at
  end

  test "an empty audience goes straight to sent" do
    @campaign.update!(recipients: ["nope"])
    Sidekiq::Testing.fake! { PushCampaignEvaluateJob.new.perform(@campaign.id) }
    assert_equal "sent", @campaign.reload.status
  end

  test "a campaign not in evaluating is ignored" do
    @campaign.update!(status: "draft")
    PushCampaignEvaluateJob.new.perform(@campaign.id)
    assert_equal 0, @campaign.deliveries.count
  end

  test "a busy segment or a ClickHouse outage is re-queued with growing waits, ten attempts in all, then fails as segment_busy" do
    seg = Segment.create!(project: projects(:one), name: "S", definition: PushCampaignFixtures::SEGMENT_DEFINITION)
    @campaign.update!(audience_type: "segment", segment: seg, recipients: [], busy_attempts: 8)
    assert_equal 10, PushCampaignEvaluateJob::MAX_BUSY_ATTEMPTS
    assert_in_delta 1.minute, PushCampaignEvaluateJob.backoff(1), 15.seconds
    assert_in_delta 30.minutes, PushCampaignEvaluateJob.backoff(9), 7.5.minutes
    assert_in_delta 30.minutes, PushCampaignEvaluateJob.backoff(50), 7.5.minutes
    Sidekiq::Testing.fake! do
      PushCampaignEvaluateJob.clear
      @campaign.update_columns(updated_at: 1.hour.ago)
      PushCampaigns::Audience.stub(:freeze!, ->(*) { raise Clickhouse::Unavailable, "segments" }) { PushCampaignEvaluateJob.new.perform(@campaign.id) }
      assert_equal 1, PushCampaignEvaluateJob.jobs.size
      assert_equal "evaluating", @campaign.reload.status
      assert_in_delta Time.current, @campaign.updated_at, 5.seconds, "a busy retry must look fresh to the tick"
      PushCampaigns::Audience.stub(:freeze!, ->(*) { raise Segments::Busy }) { PushCampaignEvaluateJob.new.perform(@campaign.id) }
    end
    assert_equal %w[failed segment_busy], [@campaign.reload.status, @campaign.failure_reason]
  end

  test "an invalid segment fails as segment_invalid and a heavy one as query_too_heavy" do
    seg = Segment.create!(project: projects(:one), name: "S", definition: PushCampaignFixtures::SEGMENT_DEFINITION)
    @campaign.update!(audience_type: "segment", segment: seg, recipients: [])
    PushCampaigns::Audience.stub(:freeze!, ->(*) { raise Segments::InvalidDefinition, "x" }) { PushCampaignEvaluateJob.new.perform(@campaign.id) }
    assert_equal %w[failed segment_invalid], [@campaign.reload.status, @campaign.failure_reason]
    @campaign.update!(status: "evaluating", failure_reason: nil)
    PushCampaigns::Audience.stub(:freeze!, ->(*) { raise Analytics::QueryTooHeavy }) { PushCampaignEvaluateJob.new.perform(@campaign.id) }
    assert_equal "query_too_heavy", @campaign.reload.failure_reason
  end

  test "exhausted retries fail the campaign with a reason and an audit row" do
    EnterpriseSubscription.create!(instance: instances(:one), active: true, start_date: 1.day.ago, end_date: 1.year.from_now, total_maus: 100)
    handler = PushCampaignEvaluateJob.sidekiq_retries_exhausted_block
    handler.call({ "args" => [@campaign.id], "class" => "PushCampaignEvaluateJob" }, RuntimeError.new("boom"))
    @campaign.reload
    assert_equal %w[failed evaluation_error], [@campaign.status, @campaign.failure_reason]
    assert @campaign.finished_at
    assert_equal 1, AuditEvent.where(action: "push_campaign.failed").count
  end
end
