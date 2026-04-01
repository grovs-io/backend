require "test_helper"

class ActionsServiceTest < ActiveSupport::TestCase
  fixtures :devices, :links, :domains, :redirect_configs, :projects, :instances, :actions

  setup do
    @device = devices(:ios_device)
    @link   = links(:basic_link)
  end

  # ---------------------------------------------------------------------------
  # create_if_needed
  # ---------------------------------------------------------------------------

  test "creates action when none exists for device+link pair" do
    device = devices(:android_device)
    link   = links(:basic_link)
    Action.where(device_id: device.id, link_id: link.id).delete_all

    assert_difference "Action.count", 1 do
      ActionsService.create_if_needed(device, link)
    end
  end

  test "skips creation when a recent unhandled action exists" do
    # Fixture :recent_action is 1 minute old and unhandled for ios_device + basic_link
    assert_no_difference "Action.count" do
      ActionsService.create_if_needed(@device, @link)
    end
  end

  test "creates new action when existing one is older than VALIDITY_MINUTES" do
    Action.where(device_id: @device.id, link_id: @link.id, handled: false)
          .update_all(created_at: (Grovs::Links::VALIDITY_MINUTES + 1).minutes.ago)

    assert_difference "Action.count", 1 do
      ActionsService.create_if_needed(@device, @link)
    end
  end

  test "creates new action when existing one is exactly at VALIDITY_MINUTES boundary" do
    # At exactly VALIDITY_MINUTES ago the condition is `< VALIDITY_MINUTES.minutes.ago`
    # so an action created exactly at the boundary IS expired
    Action.where(device_id: @device.id, link_id: @link.id, handled: false)
          .update_all(created_at: Grovs::Links::VALIDITY_MINUTES.minutes.ago)

    assert_difference "Action.count", 1 do
      ActionsService.create_if_needed(@device, @link)
    end
  end

  # ---------------------------------------------------------------------------
  # action_for_device
  # ---------------------------------------------------------------------------

  test "returns most recent action within validity window" do
    action = ActionsService.action_for_device(@device)

    assert_not_nil action
    assert_equal @device.id, action.device_id
  end

  test "returns nil when all actions are expired" do
    Action.where(device_id: @device.id)
          .update_all(created_at: (Grovs::Links::VALIDITY_MINUTES + 1).minutes.ago)

    assert_nil ActionsService.action_for_device(@device)
  end

  test "returns newest action when multiple valid actions exist" do
    newest = Action.create!(device_id: @device.id, link_id: @link.id, handled: false)
    result = ActionsService.action_for_device(@device)

    assert_equal newest.id, result.id
  end

  # ---------------------------------------------------------------------------
  # mark_actions_before_action_as_handled
  # ---------------------------------------------------------------------------

  test "marks all actions up to and including the given action as handled" do
    old    = actions(:old_action)    # 10 min ago
    recent = actions(:recent_action) # 1 min ago

    ActionsService.mark_actions_before_action_as_handled(recent)

    assert old.reload.handled
    assert recent.reload.handled
  end

  test "destroys orphaned actions whose link has been deleted" do
    second_link = links(:second_link)
    orphan = Action.create!(device_id: @device.id, link_id: second_link.id,
                            handled: false, created_at: 5.minutes.ago)
    second_link.delete
    recent = actions(:recent_action)

    ActionsService.mark_actions_before_action_as_handled(recent)

    assert_not Action.exists?(orphan.id), "Orphan action should be destroyed"
    assert recent.reload.handled
  end
end
