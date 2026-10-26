require "test_helper"

class StripeWebhookPlanSyncTest < ActiveSupport::TestCase
  fixtures :instances, :stripe_payment_intents, :stripe_subscriptions, :stripe_webhook_messages, :users

  setup do
    @instance = instances(:one)
    @payment_intent = stripe_payment_intents(:one)
    @active_sub = stripe_subscriptions(:active_sub)

    @mock_project_helper = Minitest::Mock.new
    StripeService.instance_variable_set(:@project_helper, @mock_project_helper)
  end

  teardown do
    StripeService.instance_variable_set(:@project_helper, nil)
  end

  def build_event(type:, object:, id: nil)
    Stripe::Event.construct_from({
      id: id || "evt_test_#{SecureRandom.hex(4)}",
      type: type,
      data: { object: object }
    })
  end

  def flat_remote(price_id, cancel_at: nil, status: "active", pause_collection: nil)
    Stripe::Subscription.construct_from(
      id: @active_sub.subscription_id, status: status, cancel_at: cancel_at, pause_collection: pause_collection,
      items: { data: [{ id: "si_flat", price: { id: price_id, recurring: { interval: "month" } } }] }
    )
  end

  def updated_event(price_id: nil, **overrides)
    object = {
      id: @active_sub.subscription_id, customer: @active_sub.customer_id,
      cancel_at: nil, cancel_at_period_end: false, canceled_at: nil,
      trial_end: nil, status: "active", pause_collection: nil,
      items: { data: [{ id: "si_flat", price: { id: price_id } }] }
    }.merge(overrides)
    build_event(type: "customer.subscription.updated", object: object)
  end

  test "checkout.session.completed takes the plan from the subscription price, not the latest intent" do
    StripeSubscription.where(instance_id: @instance.id).delete_all
    paid = StripePaymentIntent.create!(instance: @instance, user: users(:admin_user), intent_id: "cs_paid_tab", product_type: "scale_1m")
    StripePaymentIntent.create!(instance: @instance, user: users(:admin_user), intent_id: "cs_later_tab", product_type: "growth_250k")
    event = build_event(type: "checkout.session.completed",
                        object: { id: "cs_paid_tab", subscription: "sub_two_tabs", customer: "cus_t", client_reference_id: @instance.id.to_s })
    remote = Stripe::Subscription.construct_from(id: "sub_two_tabs", status: "active",
                                                 items: { data: [{ id: "si_t", price: { id: "price_test_s1m_m" } }] })

    Stripe::Subscription.stub(:retrieve, ->(_) { remote }) { StripeService.handle_webhook(event) }

    sub = StripeSubscription.find_by!(subscription_id: "sub_two_tabs")
    assert_equal "scale_1m", sub.product_type
    assert_equal paid.id, sub.stripe_payment_intent_id
    assert sub.active
  end

  test "checkout.session.completed keeps the intent product_type for a non-flat price" do
    StripeSubscription.where(instance_id: @instance.id).delete_all
    event = build_event(type: "checkout.session.completed",
                        object: { subscription: "sub_legacy_new", customer: "cus_l", client_reference_id: @instance.id.to_s })
    remote = Stripe::Subscription.construct_from(id: "sub_legacy_new", status: "active",
                                                 items: { data: [{ id: "si_l", price: { id: ENV["STRIPE_STANDARD_PRICE_ID"] } }] })

    Stripe::Subscription.stub(:retrieve, ->(_) { remote }) { StripeService.handle_webhook(event) }

    assert_equal @payment_intent.product_type, StripeSubscription.find_by!(subscription_id: "sub_legacy_new").product_type
  end

  test "subscription.updated on a legacy row makes no Stripe call and keeps product_type" do
    Stripe::Subscription.stub(:retrieve, ->(_) { flunk "legacy path must not call Stripe" }) do
      StripeService.handle_webhook(updated_event(price_id: ENV["STRIPE_STANDARD_PRICE_ID"]))
    end
    assert_equal "pro", @active_sub.reload.product_type
  end

  test "owner moving a legacy sub to a flat price switches product_type" do
    Stripe::Subscription.stub(:retrieve, ->(_) { flat_remote("price_test_g250_m") }) do
      StripeService.handle_webhook(updated_event(price_id: "price_test_g250_m"))
    end
    assert_equal "growth_250k", @active_sub.reload.product_type
  end

  test "band change reads current Stripe state, so a late older event cannot restore the old band" do
    @active_sub.update!(product_type: "growth_500k")
    Stripe::Subscription.stub(:retrieve, ->(_) { flat_remote("price_test_g500_m") }) do
      StripeService.handle_webhook(updated_event(price_id: "price_test_g250_m"))
    end
    assert_equal "growth_500k", @active_sub.reload.product_type
  end

  test "band change is applied even when the same event carries a scheduled cancel" do
    @active_sub.update!(product_type: "growth_250k")
    cancel_at = 20.days.from_now.to_i
    Stripe::Subscription.stub(:retrieve, ->(_) { flat_remote("price_test_g500_m", cancel_at: cancel_at) }) do
      StripeService.handle_webhook(updated_event(price_id: "price_test_g500_m", cancel_at: cancel_at, cancel_at_period_end: true))
    end
    @active_sub.reload
    assert_equal "growth_500k", @active_sub.product_type
    assert_in_delta cancel_at, @active_sub.cancels_at.to_i, 1
    assert @active_sub.active
  end

  test "flat: late cancel event after an undo does not restore cancels_at" do
    @active_sub.update!(product_type: "growth_250k", cancels_at: nil)
    Stripe::Subscription.stub(:retrieve, ->(_) { flat_remote("price_test_g250_m", cancel_at: nil) }) do
      StripeService.handle_webhook(updated_event(price_id: "price_test_g250_m", cancel_at: 20.days.from_now.to_i, cancel_at_period_end: true))
    end
    assert_nil @active_sub.reload.cancels_at
  end

  test "undo cancel clears cancels_at" do
    @active_sub.update!(cancels_at: 10.days.from_now)
    StripeService.handle_webhook(updated_event)
    assert_nil @active_sub.reload.cancels_at
  end

  test "subscription.updated propagates a failed retrieve for a flat row" do
    @active_sub.update!(product_type: "growth_250k")
    Stripe::Subscription.stub(:retrieve, ->(_) { raise Stripe::APIConnectionError, "down" }) do
      assert_raises(Stripe::APIConnectionError) { StripeService.handle_webhook(updated_event(price_id: "price_test_g250_m")) }
    end
  end

  test "flat: scheduled cancel followed by a pause ends up paused, not canceled" do
    @active_sub.update!(product_type: "growth_250k", cancels_at: nil)
    cancel_at = 20.days.from_now.to_i

    Stripe::Subscription.stub(:retrieve, ->(_) { flat_remote("price_test_g250_m", cancel_at: cancel_at) }) do
      StripeService.handle_webhook(updated_event(price_id: "price_test_g250_m", cancel_at: cancel_at, cancel_at_period_end: true))
    end
    @active_sub.reload
    assert @active_sub.active
    assert_in_delta cancel_at, @active_sub.cancels_at.to_i, 1

    @mock_project_helper.expect(:current_mau, 5000, [@instance])
    Stripe::Subscription.stub(:retrieve, lambda { |_|
      flat_remote("price_test_g250_m", cancel_at: cancel_at, pause_collection: { behavior: "mark_uncollectible" })
    }) do
      StripeService.handle_webhook(updated_event(price_id: "price_test_g250_m", cancel_at: cancel_at, cancel_at_period_end: true))
    end
    @active_sub.reload
    assert_equal "paused", @active_sub.status
    assert_not @active_sub.active
  end

  test "flat: pause lifting with no remote cancel_at clears cancels_at and reactivates" do
    @active_sub.update!(product_type: "growth_250k", status: "paused", active: false, cancels_at: 10.days.from_now)
    Stripe::Subscription.stub(:retrieve, ->(_) { flat_remote("price_test_g250_m", cancel_at: nil, status: "active") }) do
      StripeService.handle_webhook(updated_event(price_id: "price_test_g250_m"))
    end
    @active_sub.reload
    assert_nil @active_sub.cancels_at
    assert @active_sub.active
    assert_equal "active", @active_sub.status
  end

  test "flat: a late past_due event is overridden by the current active remote state" do
    @active_sub.update!(product_type: "growth_250k")
    Stripe::Subscription.stub(:retrieve, ->(_) { flat_remote("price_test_g250_m", status: "active") }) do
      StripeService.handle_webhook(updated_event(price_id: "price_test_g250_m", status: "past_due"))
    end
    @active_sub.reload
    assert @active_sub.active
    assert_equal "active", @active_sub.status
    assert_not @instance.reload.quota_exceeded
  end

  test "checkout hydration of a flat sub applies cancels_at already present on the remote" do
    StripeSubscription.where(instance_id: @instance.id).delete_all
    StripePaymentIntent.create!(instance: @instance, user: users(:admin_user), intent_id: "cs_flat_cancel", product_type: "growth_250k")
    cancel_at = 15.days.from_now.to_i
    event = build_event(type: "checkout.session.completed",
                        object: { id: "cs_flat_cancel", subscription: "sub_flat_cancel", customer: "cus_f", client_reference_id: @instance.id.to_s })
    remote = Stripe::Subscription.construct_from(
      id: "sub_flat_cancel", status: "active", cancel_at: cancel_at,
      items: { data: [{ id: "si_flat", price: { id: "price_test_g250_m", recurring: { interval: "month" } } }] }
    )

    Stripe::Subscription.stub(:retrieve, ->(_) { remote }) { StripeService.handle_webhook(event) }

    sub = StripeSubscription.find_by!(subscription_id: "sub_flat_cancel")
    assert_equal "growth_250k", sub.product_type
    assert_in_delta cancel_at, sub.cancels_at.to_i, 1
    assert sub.active
  end

  test "flat: remote status canceled marks inactive and stamps cancels_at" do
    @active_sub.update!(product_type: "growth_250k", cancels_at: nil)
    @mock_project_helper.expect(:current_mau, 5000, [@instance])
    Stripe::Subscription.stub(:retrieve, ->(_) { flat_remote("price_test_g250_m", status: "canceled") }) do
      StripeService.handle_webhook(updated_event(price_id: "price_test_g250_m", status: "canceled"))
    end
    @active_sub.reload
    assert_not @active_sub.active
    assert_equal "canceled", @active_sub.status
    assert_not_nil @active_sub.cancels_at
  end

  def payment_fail_event
    build_event(type: "invoice.payment_failed", object: { subscription: @active_sub.subscription_id, customer: @active_sub.customer_id })
  end

  test "flat: a late invoice.payment_failed is overridden by an active remote state" do
    @active_sub.update!(product_type: "growth_250k")
    Stripe::Subscription.stub(:retrieve, ->(_) { flat_remote("price_test_g250_m", status: "active") }) do
      StripeService.handle_webhook(payment_fail_event)
    end
    @active_sub.reload
    assert @active_sub.active
    assert_equal "active", @active_sub.status
    assert_not @instance.reload.quota_exceeded
  end

  test "flat: invoice.payment_failed hydrates to the remote's past_due state" do
    @active_sub.update!(product_type: "growth_250k")
    @mock_project_helper.expect(:current_mau, 5000, [@instance])
    Stripe::Subscription.stub(:retrieve, ->(_) { flat_remote("price_test_g250_m", status: "past_due") }) do
      StripeService.handle_webhook(payment_fail_event)
    end
    @active_sub.reload
    assert_not @active_sub.active
    assert_equal "past_due", @active_sub.status
  end

  test "generate_portal_link falls back to the unresolved row's customer_id" do
    instance_two = instances(:two)
    StripeSubscription.where(instance_id: instance_two.id).delete_all
    spi = StripePaymentIntent.create!(user: users(:admin_user), instance: instance_two, intent_id: "pi_unresolved")
    StripeSubscription.create!(instance: instance_two, stripe_payment_intent: spi, active: false, status: "past_due",
                                subscription_id: "sub_unresolved", customer_id: "cus_unresolved")

    portal_url = "https://billing.stripe.com/p/session/unresolved"
    fake_create = lambda { |params|
      assert_equal "cus_unresolved", params[:customer]
      OpenStruct.new(url: portal_url)
    }

    Stripe::BillingPortal::Session.stub(:create, fake_create) do
      assert_equal portal_url, StripeService.generate_portal_link(instance_two)
    end
  end

  test "payment_failed hydrates the subscription named in the event, not an older row sharing the customer" do
    shared_customer = "cus_shared_#{SecureRandom.hex(4)}"
    old_row = StripeSubscription.create!(instance: @instance, stripe_payment_intent: @payment_intent,
                                          subscription_id: "sub_old_#{SecureRandom.hex(4)}", customer_id: shared_customer,
                                          product_type: "growth_250k", active: false, status: "canceled")
    new_row = StripeSubscription.create!(instance: @instance, stripe_payment_intent: @payment_intent,
                                          subscription_id: "sub_new_#{SecureRandom.hex(4)}", customer_id: shared_customer,
                                          product_type: "growth_250k", active: true, status: "active")
    event = build_event(type: "invoice.payment_failed", object: { subscription: new_row.subscription_id, customer: shared_customer })
    remote = Stripe::Subscription.construct_from(
      id: new_row.subscription_id, status: "active",
      items: { data: [{ id: "si_flat", price: { id: "price_test_g250_m", recurring: { interval: "month" } } }] }
    )

    Stripe::Subscription.stub(:retrieve, ->(_) { remote }) { StripeService.handle_webhook(event) }

    new_row.reload
    assert new_row.active
    assert_equal "active", new_row.status
    old_row.reload
    assert_equal "canceled", old_row.status
    assert_not old_row.active
  end

  test "payment_failed on a one-off invoice (no subscription) finds row by customer, not by nil subscription_id" do
    customer_id = "cus_oneoff_#{SecureRandom.hex(4)}"
    row_for_customer = StripeSubscription.create!(instance: @instance, stripe_payment_intent: @payment_intent,
                                                   subscription_id: "sub_oneoff_#{SecureRandom.hex(4)}", customer_id: customer_id,
                                                   product_type: "pro", active: true, status: "active")
    null_sub_row = StripeSubscription.create!(instance: @instance, stripe_payment_intent: @payment_intent,
                                               subscription_id: "sub_other_#{SecureRandom.hex(4)}", customer_id: "cus_other_#{SecureRandom.hex(4)}",
                                               product_type: "pro", active: true, status: "active")
    null_sub_row.update_column(:subscription_id, nil)

    event = build_event(type: "invoice.payment_failed", object: { subscription: nil, customer: customer_id })
    @mock_project_helper.expect(:current_mau, 5000, [@instance])
    StripeService.handle_webhook(event)

    row_for_customer.reload
    assert_not row_for_customer.active
    assert_equal "payment_failed", row_for_customer.status

    null_sub_row.reload
    assert null_sub_row.active
    assert_equal "active", null_sub_row.status
  end
end
