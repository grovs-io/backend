require "test_helper"

class OrphanedActionsCleanupJobTest < ActiveSupport::TestCase
  fixtures :devices, :links, :domains, :redirect_configs, :projects, :instances, :actions

  setup do
    @job = OrphanedActionsCleanupJob.new
    @device = devices(:ios_device)
    @link = links(:basic_link)
  end

  test "deletes actions whose link has been deleted" do
    second_link = links(:second_link)
    orphan = Action.create!(device_id: @device.id, link_id: second_link.id,
                            handled: false, created_at: 5.minutes.ago)
    second_link.delete

    @job.perform

    assert_not Action.exists?(orphan.id), "Orphan action should be destroyed"
  end

  test "preserves actions whose link still exists" do
    valid = actions(:recent_action)

    @job.perform

    assert Action.exists?(valid.id), "Valid action should be preserved"
  end

  test "handles empty table gracefully" do
    Action.delete_all

    assert_nothing_raised do
      @job.perform
    end
  end

  test "deletes multiple orphans" do
    second_link = links(:second_link)
    orphans = 3.times.map do |i|
      Action.create!(device_id: @device.id, link_id: second_link.id,
                      handled: false, created_at: (i + 1).minutes.ago)
    end
    second_link.delete

    @job.perform

    orphans.each do |orphan|
      assert_not Action.exists?(orphan.id), "Orphan action #{orphan.id} should be destroyed"
    end
  end
end
