require "test_helper"

class StripeServiceCheckoutSessionsTest < ActiveSupport::TestCase
  fixtures :instances, :stripe_payment_intents, :stripe_subscriptions, :users

  setup do
    @instance = instances(:one)
  end

  def checkout_session(id, status, subscription: nil)
    OpenStruct.new(id: id, status: status, subscription: subscription)
  end

  def recent_intent(intent_id, **attrs)
    StripePaymentIntent.create!({ instance: @instance, user: users(:admin_user), intent_id: intent_id, product_type: "growth_250k" }.merge(attrs))
  end

  # active_sub fixture references payment_intent :one — clear it first to avoid an FK hit.
  def clear_instance_payment_intents
    StripeSubscription.where(instance: @instance).delete_all
    StripePaymentIntent.where(instance: @instance).delete_all
  end

  test "expire_open_checkout_sessions expires recent open sessions and skips old ones" do
    clear_instance_payment_intents
    recent_intent("cs_recent")
    recent_intent("cs_old", created_at: 2.days.ago)
    retrieved = []
    expired = []
    version = { stripe_version: StripeService::CHECKOUT_API_VERSION }

    Stripe::Checkout::Session.stub(:retrieve, lambda { |id, opts|
      retrieved << [id, opts]
      checkout_session(id, "open")
    }) do
      Stripe::Checkout::Session.stub(:expire, ->(id, params, opts) { expired << [id, params, opts] }) do
        StripeService.expire_open_checkout_sessions(@instance)
      end
    end

    assert_equal [["cs_recent", version]], retrieved
    assert_equal [["cs_recent", {}, version]], expired
  end

  test "a completed session whose webhook has not arrived blocks checkout" do
    clear_instance_payment_intents
    recent_intent("cs_paid")

    Stripe::Checkout::Session.stub(:retrieve, ->(id, *) { checkout_session(id, "complete", subscription: "sub_not_yet_seen") }) do
      assert_raises(StripeService::CheckoutAlreadyCompleted) { StripeService.expire_open_checkout_sessions(@instance) }
    end
  end

  test "a completed session whose subscription already ended does not block resubscribing" do
    clear_instance_payment_intents
    intent = recent_intent("cs_done")
    StripeSubscription.create!(instance: @instance, stripe_payment_intent: intent, subscription_id: "sub_cancelled_same_day",
                               customer_id: "cus_ended", active: false, status: "canceled", product_type: "growth_250k")

    Stripe::Checkout::Session.stub(:retrieve, ->(id, *) { checkout_session(id, "complete", subscription: "sub_cancelled_same_day") }) do
      assert_nothing_raised { StripeService.expire_open_checkout_sessions(@instance) }
    end
  end

  test "a session completed between retrieve and expire blocks checkout" do
    clear_instance_payment_intents
    recent_intent("cs_racing")
    states = [checkout_session("cs_racing", "open"), checkout_session("cs_racing", "complete", subscription: "sub_racing")]

    Stripe::Checkout::Session.stub(:retrieve, ->(*) { states.shift }) do
      Stripe::Checkout::Session.stub(:expire, ->(*) { raise Stripe::InvalidRequestError.new("Only open sessions can be expired", nil) }) do
        assert_raises(StripeService::CheckoutAlreadyCompleted) { StripeService.expire_open_checkout_sessions(@instance) }
      end
    end
  end

  test "an expire failure that leaves the session open propagates" do
    clear_instance_payment_intents
    recent_intent("cs_stuck")

    Stripe::Checkout::Session.stub(:retrieve, ->(id, *) { checkout_session(id, "open") }) do
      Stripe::Checkout::Session.stub(:expire, ->(*) { raise Stripe::InvalidRequestError.new("boom", nil) }) do
        assert_raises(Stripe::InvalidRequestError) { StripeService.expire_open_checkout_sessions(@instance) }
      end
    end
  end

  test "expired sessions and ids that are not sessions are ignored; other retrieve errors propagate" do
    clear_instance_payment_intents
    recent_intent("cs_expired")
    recent_intent("pi_not_a_session", product_type: "scale_up")
    missing = Stripe::InvalidRequestError.new("No such checkout.session", nil, code: "resource_missing")
    fake_retrieve = ->(id, *) { id.start_with?("pi_") ? raise(missing) : checkout_session(id, "expired") }

    Stripe::Checkout::Session.stub(:retrieve, fake_retrieve) do
      assert_nothing_raised { StripeService.expire_open_checkout_sessions(@instance) }
    end

    Stripe::Checkout::Session.stub(:retrieve, ->(*) { raise Stripe::InvalidRequestError.new("Invalid API key", nil) }) do
      assert_raises(Stripe::InvalidRequestError) { StripeService.expire_open_checkout_sessions(@instance) }
    end
  end
end
