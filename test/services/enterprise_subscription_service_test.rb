require "test_helper"

class EnterpriseSubscriptionServiceTest < ActiveSupport::TestCase
  fixtures :instances

  setup do
    @instance = instances(:one)
    # Clean up any existing enterprise subscriptions for the fixture instance
    EnterpriseSubscription.where(instance_id: @instance.id).delete_all
  end

  test "create creates enterprise subscription" do
    sub = EnterpriseSubscriptionService.create(
      instance_id: @instance.id,
      start_date: Date.today,
      end_date: Date.today + 365,
      total_maus: 100_000,
      active: true
    )

    assert sub.persisted?
    assert_equal @instance.id, sub.instance_id
    assert_equal 100_000, sub.total_maus
    assert sub.active
  end

  test "create raises for blank required fields" do
    error = assert_raises(ArgumentError) do
      EnterpriseSubscriptionService.create(
        instance_id: @instance.id,
        start_date: nil,
        end_date: "",
        total_maus: nil,
        active: true
      )
    end
    assert_match(/start_date/, error.message)
    assert_match(/end_date/, error.message)
    assert_match(/total_maus/, error.message)
  end

  test "create raises for single blank field" do
    error = assert_raises(ArgumentError) do
      EnterpriseSubscriptionService.create(
        instance_id: @instance.id,
        start_date: Date.today,
        end_date: Date.today + 365,
        total_maus: nil,
        active: true
      )
    end
    assert_match(/total_maus/, error.message)
    assert_no_match(/start_date/, error.message)
  end

  test "create raises for missing instance" do
    assert_raises(ActiveRecord::RecordNotFound) do
      EnterpriseSubscriptionService.create(
        instance_id: -1,
        start_date: Date.today,
        end_date: Date.today + 365,
        total_maus: 50_000,
        active: true
      )
    end
  end

  test "create raises for duplicate active subscription" do
    EnterpriseSubscriptionService.create(
      instance_id: @instance.id,
      start_date: Date.today,
      end_date: Date.today + 365,
      total_maus: 100_000,
      active: true
    )

    assert_raises(ArgumentError) do
      EnterpriseSubscriptionService.create(
        instance_id: @instance.id,
        start_date: Date.today,
        end_date: Date.today + 365,
        total_maus: 50_000,
        active: true
      )
    end
  end

  test "update updates subscription fields" do
    sub = EnterpriseSubscriptionService.create(
      instance_id: @instance.id,
      start_date: Date.today,
      end_date: Date.today + 365,
      total_maus: 100_000,
      active: true
    )

    updated = EnterpriseSubscriptionService.update(
      id: sub.id,
      attrs: { total_maus: 200_000 }
    )

    assert_equal 200_000, updated.total_maus
  end

  test "update raises for missing subscription" do
    assert_raises(ActiveRecord::RecordNotFound) do
      EnterpriseSubscriptionService.update(id: -1, attrs: { active: false })
    end
  end
end
