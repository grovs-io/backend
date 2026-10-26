require "test_helper"
require "rake"

class PushCampaignsRecountTaskTest < ActiveSupport::TestCase
  fixtures :instances, :projects, :devices, :visitors

  setup do
    Rails.application.load_tasks if Rake::Task.tasks.empty?
    Rake::Task["push_campaigns:recount"].reenable
    @saved = ENV["CAMPAIGN_ID"]
    @campaign = PushCampaign.create!(project: projects(:one), name: "r", title: "t", body: "b", audience_type: "visitors", recipients: ["x"],
                                     status: "sent", delivered: 9)
    PushDelivery.create!(push_campaign: @campaign, visitor: visitors(:ios_visitor), device_id: devices(:ios_device).id, platform: "ios",
                         status: "delivered")
  end

  teardown { @saved.nil? ? ENV.delete("CAMPAIGN_ID") : ENV["CAMPAIGN_ID"] = @saved }

  def run_task
    ENV["CAMPAIGN_ID"] = @campaign.hashid
    capture_io { Rake::Task["push_campaigns:recount"].invoke }
  end

  test "rebuilds drifted counters from the rows, folding the shards into the row" do
    PushCampaign.bump!(@campaign.id, delivered: 3)
    out, = run_task
    assert_match(/fixed .*delivered/, out)
    assert_equal 1, @campaign.reload.delivered
    assert_equal 0, @campaign.counter_shards.sum(&:delivered)
  end

  test "reports an exact campaign as such" do
    @campaign.update_columns(delivered: 1, queued: 1)
    out, = run_task
    assert_match(/already exact/, out)
  end
end
