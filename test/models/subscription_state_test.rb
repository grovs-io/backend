require "test_helper"

class SubscriptionStateTest < ActiveSupport::TestCase
  fixtures :subscription_states, :projects, :devices, :instances, :domains, :redirect_configs

  # === creation with all associations ===

  test "can be created with all associations populated" do
    link = Link.create!(
      domain: domains(:one),
      redirect_config: redirect_configs(:one),
      path: "sub-state-test-path",
      generated_from_platform: Grovs::Platforms::IOS
    )

    state = SubscriptionState.new(
      project: projects(:one),
      original_transaction_id: "orig_txn_full_assoc",
      device: devices(:ios_device),
      link: link,
      product_id: "com.test.full",
      latest_transaction_id: "txn_full_001",
      purchase_type: "subscription"
    )
    assert state.save
    state.reload

    assert_equal projects(:one), state.project
    assert_equal devices(:ios_device), state.device
    assert_equal link, state.link
    assert_equal "com.test.full", state.product_id
    assert_equal "txn_full_001", state.latest_transaction_id
    assert_equal "subscription", state.purchase_type
  end

  # === uniqueness of (project_id, original_transaction_id) ===

  test "project and original_transaction_id combination must be unique" do
    existing = subscription_states(:premium_sub)
    duplicate = SubscriptionState.new(
      project: existing.project,
      original_transaction_id: existing.original_transaction_id,
      product_id: "com.test.duplicate"
    )
    assert_raises(ActiveRecord::RecordNotUnique) do
      duplicate.save(validate: false)
    end
  end
end
