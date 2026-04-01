require "test_helper"

class StripePaymentIntentTest < ActiveSupport::TestCase
  fixtures :stripe_payment_intents, :users, :instances, :stripe_subscriptions

  # === associations ===

  test "belongs to user" do
    spi = stripe_payment_intents(:one)
    assert_equal users(:admin_user), spi.user
  end

  test "belongs to instance" do
    spi = stripe_payment_intents(:one)
    assert_equal instances(:one), spi.instance
  end

  test "has one stripe subscription" do
    spi = stripe_payment_intents(:one)
    assert_not_nil spi.stripe_subscription
    assert_equal stripe_subscriptions(:active_sub), spi.stripe_subscription
  end

  # === creation ===

  test "can be created with valid attributes" do
    spi = StripePaymentIntent.new(
      user: users(:admin_user),
      instance: instances(:one),
      intent_id: "pi_new_intent",
      product_type: "pro"
    )
    assert spi.save
    assert_equal "pi_new_intent", spi.reload.intent_id
  end

  test "requires user" do
    spi = StripePaymentIntent.new(
      instance: instances(:one),
      intent_id: "pi_no_user"
    )
    assert_not spi.save
  end
end
