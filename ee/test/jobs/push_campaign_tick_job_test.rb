require "test_helper"
require "sidekiq/testing"

class PushCampaignTickJobTest < ActiveSupport::TestCase
  fixtures :instances, :projects, :visitors, :devices

  setup do
    devices(:ios_device).update_columns(push_token: "tok")
    @campaign = PushCampaign.create!(project: projects(:one), name: "n", title: "t", body: "b", status: "sending",
                                     audience_type: "visitors", recipients: [visitors(:ios_visitor).uuid])
    PushCampaigns::Audience.freeze!(@campaign)
  end

  test "resets stale claims and re-enqueues deliver jobs for sending campaigns with due rows" do
    @campaign.deliveries.update_all(status: "claimed", updated_at: 11.minutes.ago)
    Sidekiq::Testing.fake! do
      PushCampaignDeliverJob.clear
      PushCampaignTickJob.new.perform
      assert_equal PushCampaignEvaluateJob::PARALLELISM, PushCampaignDeliverJob.jobs.size
    end
    assert_equal "pending", @campaign.deliveries.first.reload.status
  end

  test "releases due scheduled campaigns, local-time ones 14 hours early" do
    # Scheduled directly (validation applies to the send transition), with a due time already in the past for the plain one.
    plain, local, later = [[1.minute.ago, false], [13.hours.from_now, true], [1.hour.from_now, false]].map do |at, local_time|
      c = PushCampaign.create!(project: projects(:one), name: "s", title: "t", body: "b", audience_type: "visitors", recipients: [visitors(:ios_visitor).uuid])
      c.update_columns(status: "scheduled", scheduled_at: at, local_time: local_time)
      c
    end
    Sidekiq::Testing.fake! do
      PushCampaignEvaluateJob.clear
      PushCampaignTickJob.new.perform
      assert_equal [plain.id, local.id].sort, PushCampaignEvaluateJob.jobs.map { |j| j["args"].first }.sort
    end
    assert_equal %w[evaluating evaluating scheduled], [plain, local, later].map { |c| c.reload.status }
  end

  test "a local-time campaign is released early enough for UTC+14, whatever its own zone" do
    honolulu, tokyo_due, tokyo_later = [[23.hours.from_now, "Pacific/Honolulu"], [4.hours.from_now, "Asia/Tokyo"],
                                        [6.hours.from_now, "Asia/Tokyo"]].map do |at, zone|
      c = PushCampaign.create!(project: projects(:one), name: "s", title: "t", body: "b", audience_type: "visitors", recipients: [visitors(:ios_visitor).uuid])
      c.update_columns(status: "scheduled", scheduled_at: at, local_time: true, timezone: zone)
      c
    end
    Sidekiq::Testing.fake! { PushCampaignTickJob.new.perform }
    assert_equal %w[evaluating evaluating scheduled], [honolulu, tokyo_due, tokyo_later].map { |c| c.reload.status }
  end

  test "a scheduled campaign whose segment was archived fails alone; the others are still released" do
    seg = Segment.create!(project: projects(:one), name: "S", definition: PushCampaignFixtures::SEGMENT_DEFINITION)
    doomed = PushCampaign.create!(project: projects(:one), name: "d", title: "t", body: "b", audience_type: "segment", segment: seg,
                                  recipients: [])
    doomed.update_columns(doomed.segment_snapshot_attrs.merge(status: "scheduled", scheduled_at: 1.minute.ago))
    seg.update!(archived: true)
    plain = PushCampaign.create!(project: projects(:one), name: "p", title: "t", body: "b", audience_type: "visitors",
                                 recipients: [visitors(:ios_visitor).uuid])
    plain.update_columns(status: "scheduled", scheduled_at: 1.minute.ago)
    Sidekiq::Testing.fake! do
      PushCampaignEvaluateJob.clear
      PushCampaignTickJob.new.perform
      assert_equal [[plain.id]], PushCampaignEvaluateJob.jobs.map { |j| j["args"] }
    end
    assert_equal %w[failed segment_invalid], [doomed.reload.status, doomed.failure_reason]
    assert_equal "evaluating", plain.reload.status
  end

  test "an evaluating campaign that never got its job is re-enqueued only after the longest busy wait" do
    stuck = PushCampaign.create!(project: projects(:one), name: "s", title: "t", body: "b", audience_type: "visitors",
                                 recipients: [visitors(:ios_visitor).uuid])
    stuck.update_columns(status: "evaluating", updated_at: 46.minutes.ago)
    waiting = PushCampaign.create!(project: projects(:one), name: "f", title: "t", body: "b", audience_type: "visitors",
                                   recipients: [visitors(:ios_visitor).uuid])
    waiting.update_columns(status: "evaluating", busy_attempts: 6, updated_at: 37.minutes.ago)
    Sidekiq::Testing.fake! do
      PushCampaignEvaluateJob.clear
      PushCampaignTickJob.new.perform
      assert_equal [[stuck.id]], PushCampaignEvaluateJob.jobs.map { |j| j["args"] }
    end
  end

  test "a fresh claim is left alone and a campaign with nothing due gets no job" do
    @campaign.deliveries.update_all(status: "claimed", updated_at: 1.minute.ago)
    Sidekiq::Testing.fake! do
      PushCampaignDeliverJob.clear
      PushCampaignTickJob.new.perform
      assert_equal 0, PushCampaignDeliverJob.jobs.size
    end
    assert_equal "claimed", @campaign.deliveries.first.reload.status
  end
end
