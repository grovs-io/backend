require "test_helper"

class StripeSubscriptionTest < ActiveSupport::TestCase
  fixtures :stripe_subscriptions, :stripe_payment_intents, :instances, :users

  # === associations ===

  test "belongs to instance" do
    sub = stripe_subscriptions(:active_sub)
    assert_equal instances(:one), sub.instance
  end

  test "belongs to stripe payment intent" do
    sub = stripe_subscriptions(:active_sub)
    assert_equal stripe_payment_intents(:one), sub.stripe_payment_intent
  end

  # === creation ===

  test "can be created with valid attributes" do
    sub = StripeSubscription.new(
      instance: instances(:one),
      stripe_payment_intent: stripe_payment_intents(:one),
      subscription_id: "sub_new_001",
      product_type: "pro",
      active: true,
      status: "active",
      customer_id: "cus_new_001"
    )
    assert sub.save
    assert_equal "sub_new_001", sub.reload.subscription_id
  end

  test "requires instance" do
    sub = StripeSubscription.new(
      stripe_payment_intent: stripe_payment_intents(:one),
      subscription_id: "sub_no_instance"
    )
    assert_not sub.save
  end

  # === fields ===

  test "fixture data loads correctly" do
    active = stripe_subscriptions(:active_sub)
    assert_equal true, active.active
    assert_equal "active", active.status
    assert_equal "cus_001", active.customer_id

    canceled = stripe_subscriptions(:canceled_sub)
    assert_equal false, canceled.active
    assert_equal "canceled", canceled.status
  end
end
