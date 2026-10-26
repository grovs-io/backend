require "test_helper"

class StripeServiceFlatBillingTest < ActiveSupport::TestCase
  fixtures :instances, :stripe_payment_intents, :stripe_subscriptions, :users

  setup do
    @instance = instances(:one)
    @active_sub = stripe_subscriptions(:active_sub)
  end

  test "set_usage does nothing for a flat plan" do
    @active_sub.update!(product_type: "growth_250k", subscription_item_id: "si_flat")
    Stripe::Subscription.stub(:retrieve, ->(_) { flunk "no billing-cycle lookup for flat" }) do
      Stripe::SubscriptionItem.stub(:create_usage_record, ->(*) { flunk "no usage record for flat" }) do
        assert_nil StripeService.set_usage(@instance)
      end
    end
  end

  test "set_usage still reports usage for a legacy row with nil product_type" do
    @active_sub.update!(product_type: nil, subscription_item_id: "si_test_item")
    Project.find_or_create_by!(instance: @instance, test: true) do |p|
      p.name = "T"
      p.identifier = "t-#{SecureRandom.hex(3)}"
    end
    fake_subscription = OpenStruct.new(current_period_start: 30.days.ago.to_i, current_period_end: Time.now.to_i)
    reported = false

    Stripe::Subscription.stub(:retrieve, ->(_) { fake_subscription }) do
      Stripe::SubscriptionItem.stub(:create_usage_record, lambda { |*|
        reported = true
        OpenStruct.new
      }) do
        StripeService.stub(:apply_discounts, nil) { StripeService.set_usage(@instance) }
      end
    end
    assert reported
  end

  test "cancel_subscription on a flat plan cancels at period end" do
    @active_sub.update!(product_type: "growth_250k")
    received = nil
    Stripe::Subscription.stub(:update, lambda { |id, params|
      received = [id, params]
      OpenStruct.new(id: id)
    }) do
      Stripe::Subscription.stub(:cancel, ->(*) { flunk "flat plans must not cancel immediately" }) do
        assert StripeService.cancel_subscription(@active_sub)
      end
    end
    assert_equal [@active_sub.subscription_id, { cancel_at_period_end: true }], received
  end

  # The local row is applied by SubscriptionBillingService, not here — this stays a pure Stripe call.
  test "cancel_subscription does not touch the local row" do
    @active_sub.update!(product_type: "growth_250k", cancels_at: nil)
    remote = Stripe::Subscription.construct_from(id: @active_sub.subscription_id, status: "active",
                                                  cancel_at: 20.days.from_now.to_i)
    Stripe::Subscription.stub(:update, ->(*) { remote }) do
      StripeService.cancel_subscription(@active_sub)
    end
    assert_nil @active_sub.reload.cancels_at
  end

  test "resume_cancellation clears cancel_at_period_end" do
    received = nil
    Stripe::Subscription.stub(:update, lambda { |id, params|
      received = [id, params]
      OpenStruct.new(id: id)
    }) do
      assert StripeService.resume_cancellation(@active_sub)
    end
    assert_equal [@active_sub.subscription_id, { cancel_at_period_end: false }], received
  end

  test "resume_cancellation returns false on Stripe error" do
    Stripe::Subscription.stub(:update, ->(*) { raise Stripe::StripeError, "boom" }) do
      assert_equal false, StripeService.resume_cancellation(@active_sub)
    end
  end

  test "upcoming_invoice_or_nil returns nil for invoice_upcoming_none or flexible billing_mode, else raises" do
    none = Stripe::InvalidRequestError.new("No upcoming invoices", nil, code: "invoice_upcoming_none")
    Stripe::Invoice.stub(:upcoming, ->(*) { raise none }) do
      assert_nil StripeService.upcoming_invoice_or_nil(@active_sub)
    end

    flexible = Stripe::InvalidRequestError.new(
      "The Upcoming Invoice API does not support billing_mode = flexible subscriptions.", nil
    )
    Stripe::Invoice.stub(:upcoming, ->(*) { raise flexible }) do
      assert_nil StripeService.upcoming_invoice_or_nil(@active_sub)
    end

    other = Stripe::InvalidRequestError.new("No such subscription", nil, code: "resource_missing")
    Stripe::Invoice.stub(:upcoming, ->(*) { raise other }) do
      assert_raises(Stripe::InvalidRequestError) { StripeService.upcoming_invoice_or_nil(@active_sub) }
    end
  end
end
