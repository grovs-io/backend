require "test_helper"

class EnterpriseSubscriptionTest < ActiveSupport::TestCase
  fixtures :instances

  # === validations: start_date ===

  test "invalid without start_date" do
    sub = EnterpriseSubscription.new(
      start_date: nil,
      end_date: 1.year.from_now,
      total_maus: 100_000,
      instance: instances(:one)
    )
    assert_not sub.valid?
    assert_includes sub.errors[:start_date], "can't be blank"
  end

  # === validations: end_date ===

  test "invalid without end_date" do
    sub = EnterpriseSubscription.new(
      start_date: Time.current,
      end_date: nil,
      total_maus: 100_000,
      instance: instances(:one)
    )
    assert_not sub.valid?
    assert_includes sub.errors[:end_date], "can't be blank"
  end

  # === validations: total_maus ===

  test "invalid without total_maus" do
    sub = EnterpriseSubscription.new(
      start_date: Time.current,
      end_date: 1.year.from_now,
      total_maus: nil,
      instance: instances(:one)
    )
    assert_not sub.valid?
    assert_includes sub.errors[:total_maus], "can't be blank"
  end

  # === valid record ===

  test "valid with all required fields" do
    sub = EnterpriseSubscription.new(
      start_date: Time.current,
      end_date: 1.year.from_now,
      total_maus: 100_000,
      instance: instances(:one)
    )
    assert sub.valid?
  end

  # === optional instance ===

  test "valid without instance since association is optional" do
    sub = EnterpriseSubscription.new(
      start_date: Time.current,
      end_date: 1.year.from_now,
      total_maus: 50_000,
      instance: nil
    )
    assert sub.valid?
  end

  test "defaults to active true" do
    sub = EnterpriseSubscription.create!(
      start_date: Time.current,
      end_date: 1.year.from_now,
      total_maus: 100_000,
      instance: instances(:one)
    )
    assert_equal true, sub.active
  end
end
