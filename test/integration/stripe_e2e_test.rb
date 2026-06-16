require "test_helper"

# Real end-to-end test against Stripe's TEST-mode API. Opt-in (network, ~20s):
#   STRIPE_E2E=1 bin/rails test test/integration/stripe_e2e_test.rb
# Refuses to run against a live key.
class StripeE2eTest < ActiveSupport::TestCase
  fixtures :instances, :projects, :users

  def e2e_enabled?
    ENV["STRIPE_E2E"] == "1" && ENV["STRIPE_API_KEY"].to_s.start_with?("sk_test_")
  end

  setup do
    skip "STRIPE_E2E=1 + sk_test_ key required" unless e2e_enabled?
    @instance = instances(:one)
    @customer = nil
    @stripe_sub = nil
  end

  teardown do
    Stripe::Subscription.cancel(@stripe_sub.id) rescue nil if @stripe_sub
    Stripe::Customer.delete(@customer.id) rescue nil if @customer
  end

  test "full subscription lifecycle against real Stripe" do
    price_id = ENV.fetch("STRIPE_STANDARD_PRICE_ID")

    @customer = Stripe::Customer.create(
      email: "e2e-#{SecureRandom.hex(4)}@grovs-test.invalid",
      payment_method: "pm_card_visa",
      invoice_settings: { default_payment_method: "pm_card_visa" }
    )
    @stripe_sub = Stripe::Subscription.create(customer: @customer.id, items: [{ price: price_id }])
    assert_equal "active", @stripe_sub.status

    StripeSubscription.where(instance: @instance).delete_all
    intent = StripePaymentIntent.create!(user: users(:admin_user), instance: @instance,
                                         intent_id: "e2e_#{SecureRandom.hex(4)}",
                                         product_type: "scale_up")
    subscription = StripeSubscription.create!(
      instance: @instance, subscription_id: @stripe_sub.id,
      subscription_item_id: @stripe_sub.items.data[0].id,
      customer_id: @customer.id, active: true, status: "active",
      product_type: "scale_up", stripe_payment_intent: intent
    )

    # get_subscription_details — real retrieve
    details = StripeService.get_subscription_details(subscription.subscription_id)
    assert_equal @stripe_sub.id, details.id
    assert_equal "active", details.status

    # get_billing_cycle — real period bounds
    cycle = StripeService.get_billing_cycle(subscription)
    assert cycle[:start] <= DateTime.now
    assert cycle[:end] > DateTime.now

    # usage record round-trip (metered price)
    Stripe::SubscriptionItem.create_usage_record(
      subscription.subscription_item_id,
      { quantity: 12_345, timestamp: Time.now.to_i, action: "set" }
    )
    usage = StripeService.get_usage(subscription)
    assert_equal 12_345, usage[:data][0][:total_usage]

    # upcoming invoice + snapshot — the exact fields billing reads
    invoice = StripeService.get_next_invoice(subscription)
    assert invoice[:total].is_a?(Integer)

    snap = StripeService.monthly_total_snapshot(subscription)
    assert_equal 12_345, snap[:maus_from_invoice_line]
    assert snap[:amount_cents].positive?, "12,345 MAUs must price above zero"
    assert snap[:period_end] > Time.now.to_i

    # SubscriptionBillingService on top of the real subscription
    billing = SubscriptionBillingService.new(instance: @instance)
    sub_usage = billing.current_usage
    assert_equal 12_345, sub_usage[:maus]
    assert sub_usage[:start_date].present?

    sub_details = billing.subscription_details
    assert_equal "stripe", sub_details[:type]
    assert sub_details[:details][:active]
    assert_equal snap[:amount_cents], sub_details[:amount_cents]

    # pause / resume round-trip
    StripeService.pause_subscription(subscription)
    assert_equal "void", Stripe::Subscription.retrieve(@stripe_sub.id).pause_collection.behavior
    StripeService.resume_subscription(subscription)
    assert_nil Stripe::Subscription.retrieve(@stripe_sub.id).pause_collection

    # portal link (requires a saved test-mode portal configuration)
    begin
      url = StripeService.generate_portal_link(@instance)
      assert url.start_with?("https://billing.stripe.com/"), "portal url: #{url}"
    rescue Stripe::InvalidRequestError => e
      raise unless e.message.include?("configuration")
      puts "[stripe-e2e] portal step skipped: no test-mode portal configuration saved"
    end

    # cancel — terminal state
    StripeService.cancel_subscription(subscription)
    assert_equal "canceled", Stripe::Subscription.retrieve(@stripe_sub.id).status
    @stripe_sub = nil
  end

  test "checkout session creation against real Stripe" do
    price_id = ENV.fetch("STRIPE_STANDARD_PRICE_ID")
    user = users(:admin_user)

    session = StripeService.create_checkout_session_for_product(price_id, user, "scale_up", @instance)

    assert session[:url].start_with?("https://checkout.stripe.com/"), "got: #{session[:url]}"
    intent = StripePaymentIntent.order(:id).last
    assert_equal @instance.id, intent.instance_id
    assert_equal "scale_up", intent.product_type
  end
end
