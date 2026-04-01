require "test_helper"

class StripeServiceTest < ActiveSupport::TestCase
  fixtures :instances, :stripe_payment_intents, :stripe_subscriptions, :stripe_webhook_messages, :users

  setup do
    @instance = instances(:one)
    @payment_intent = stripe_payment_intents(:one)
    @active_sub = stripe_subscriptions(:active_sub)

    @original_free_mau = ENV["FREE_MAU_COUNT"]
    @original_first_discount_threshold = ENV["FIRST_DISCOUNT_MAUS_THRESHOLD"]
    @original_first_discount_pct = ENV["FIRST_DISCOUNT_PERCENTAGE"]
    @original_second_discount_threshold = ENV["SECOND_DISCOUNT_MAUS_THRESHOLD"]
    @original_second_discount_pct = ENV["SECOND_DISCOUNT_PERCENTAGE"]

    ENV["FREE_MAU_COUNT"] = "10000"
    ENV["FIRST_DISCOUNT_MAUS_THRESHOLD"] = "50000"
    ENV["FIRST_DISCOUNT_PERCENTAGE"] = "10"
    ENV["SECOND_DISCOUNT_MAUS_THRESHOLD"] = "100000"
    ENV["SECOND_DISCOUNT_PERCENTAGE"] = "20"

    @mock_project_helper = Minitest::Mock.new
    StripeService.instance_variable_set(:@project_helper, @mock_project_helper)
  end

  teardown do
    ENV["FREE_MAU_COUNT"] = @original_free_mau
    ENV["FIRST_DISCOUNT_MAUS_THRESHOLD"] = @original_first_discount_threshold
    ENV["FIRST_DISCOUNT_PERCENTAGE"] = @original_first_discount_pct
    ENV["SECOND_DISCOUNT_MAUS_THRESHOLD"] = @original_second_discount_threshold
    ENV["SECOND_DISCOUNT_PERCENTAGE"] = @original_second_discount_pct

    StripeService.instance_variable_set(:@project_helper, nil)
  end

  def build_event(type:, object:, id: nil)
    Stripe::Event.construct_from({
      id: id || "evt_test_#{SecureRandom.hex(4)}",
      type: type,
      data: { object: object }
    })
  end

  # ============================================================
  # handle_webhook — event routing + StripeWebhookMessage
  # ============================================================

  test "handle_webhook creates record and marks processed on success" do
    event = build_event(type: "invoice.paid", object: { subscription: "sub_xyz", customer: "cus_xyz" })

    assert_difference "StripeWebhookMessage.count", 1 do
      StripeService.handle_webhook(event)
    end

    msg = StripeWebhookMessage.last
    assert_equal "invoice.paid", msg.message_type
    assert_equal event['id'], msg.stripe_event_id
    assert msg.processed, "Record should be marked processed after success"
  end

  test "handle_webhook creates record for unknown event types" do
    event = build_event(type: "unknown.event.type", object: { id: "obj_whatever" })

    assert_difference "StripeWebhookMessage.count", 1 do
      StripeService.handle_webhook(event)
    end

    msg = StripeWebhookMessage.last
    assert_equal "unknown.event.type", msg.message_type
    assert msg.processed
  end

  test "handle_webhook skips already-processed duplicate" do
    # evt_001 exists in fixtures with processed: true
    event = build_event(id: "evt_001", type: "invoice.paid", object: { subscription: "sub_xyz", customer: "cus_xyz" })

    assert_no_difference "StripeWebhookMessage.count" do
      StripeService.handle_webhook(event)
    end
  end

  test "handle_webhook reprocesses unfinished duplicate" do
    # Create an unprocessed record simulating a previous crash
    record = StripeWebhookMessage.create!(
      data: { type: "invoice.paid" },
      message_type: "invoice.paid",
      stripe_event_id: "evt_crashed",
      processed: false
    )

    event = build_event(id: "evt_crashed", type: "some.unknown.event", object: {})

    StripeService.handle_webhook(event)

    record.reload
    assert record.processed, "Previously crashed record should now be marked processed"
  end

  test "handle_webhook leaves record unprocessed when reprocess raises" do
    record = StripeWebhookMessage.create!(
      data: { type: "checkout.session.completed" },
      message_type: "checkout.session.completed",
      stripe_event_id: "evt_will_fail",
      processed: false
    )

    event = build_event(
      id: "evt_will_fail",
      type: "checkout.session.completed",
      object: { subscription: "sub_x", customer: "cus_x", client_reference_id: "nonexistent" }
    )

    # This should raise because client_reference_id doesn't match any instance
    # The handler will try Instance.find_by → nil, but handler logic varies.
    # We force a failure by stubbing process_event to raise.
    StripeService.stub(:process_event, ->(_) { raise StandardError, "transient failure" }) do
      assert_raises(StandardError) { StripeService.handle_webhook(event) }
    end

    record.reload
    assert_not record.processed, "Record should stay unprocessed so next retry can try again"
  end

  test "unknown event type does not crash" do
    event = build_event(type: "some.unknown.event", object: { id: "obj_unknown" })
    assert_nothing_raised { StripeService.handle_webhook(event) }
  end

  # ============================================================
  # checkout.session.completed → handle_subscription_started
  # ============================================================

  test "checkout.session.completed creates a StripeSubscription with correct attributes" do
    StripeSubscription.where(instance_id: @instance.id).delete_all

    event_data = build_event(
      type: "checkout.session.completed",
      object: { subscription: "sub_new_123", customer: "cus_new_123", client_reference_id: @instance.id.to_s }
    )

    assert_difference "StripeSubscription.count", 1 do
      StripeService.handle_webhook(event_data)
    end

    sub = StripeSubscription.find_by(subscription_id: "sub_new_123")
    assert_not_nil sub
    assert_equal @instance.id, sub.instance_id
    assert_equal "cus_new_123", sub.customer_id
    assert_equal @payment_intent.product_type, sub.product_type
    assert_equal @payment_intent.id, sub.stripe_payment_intent_id
    assert_equal "pending", sub.status
    assert_equal false, sub.active
  end

  test "checkout.session.completed returns early when no payment intent exists for instance" do
    empty_instance = Instance.create!(uri_scheme: "empty_#{SecureRandom.hex(4)}", api_key: SecureRandom.hex(16))

    event_data = build_event(
      type: "checkout.session.completed",
      object: { subscription: "sub_orphan", customer: "cus_orphan", client_reference_id: empty_instance.id.to_s }
    )

    assert_nothing_raised { StripeService.handle_webhook(event_data) }

    # No subscription should be created
    assert_nil StripeSubscription.find_by(subscription_id: "sub_orphan")
  end

  # ============================================================
  # customer.subscription.created → handle_subscription_created
  # ============================================================

  test "customer.subscription.created activates subscription and clears quota_exceeded" do
    @instance.update!(quota_exceeded: true)

    event_data = build_event(
      type: "customer.subscription.created",
      object: { id: @active_sub.subscription_id, status: "active", trial_end: nil, items: { data: [{ id: "si_item_001" }] } }
    )

    StripeService.handle_webhook(event_data)

    @active_sub.reload
    assert @active_sub.active
    assert_equal "active", @active_sub.status
    assert_equal "si_item_001", @active_sub.subscription_item_id

    @instance.reload
    assert_not @instance.quota_exceeded
  end

  test "customer.subscription.created does nothing when subscription not found" do
    event_data = build_event(
      type: "customer.subscription.created",
      object: { id: "sub_nonexistent_999", status: "active", trial_end: nil, items: { data: [{ id: "si_x" }] } }
    )

    # Should not crash, just return early
    assert_nothing_raised { StripeService.handle_webhook(event_data) }

    # Existing subscription should be unchanged
    @active_sub.reload
    assert @active_sub.active
    assert_equal "active", @active_sub.status
  end

  # NOTE: handle_subscription_created has an `Instance.find_by(id:)` nil guard,
  # but the DB FK constraint on stripe_subscriptions.instance_id makes this path
  # unreachable — you can't have a subscription pointing to a nonexistent instance.
  # The guard is dead code.

  # ============================================================
  # invoice.payment_failed → handle_subscription_payment_fail
  # ============================================================

  test "invoice.payment_failed deactivates subscription and sets quota_exceeded when over free MAU" do
    event_data = build_event(
      type: "invoice.payment_failed",
      object: { subscription: @active_sub.subscription_id, customer: @active_sub.customer_id }
    )

    @mock_project_helper.expect(:current_mau, 15000, [@instance])
    StripeService.handle_webhook(event_data)

    @active_sub.reload
    assert_not @active_sub.active
    assert_equal "payment_failed", @active_sub.status

    @instance.reload
    assert @instance.quota_exceeded
    @mock_project_helper.verify
  end

  test "invoice.payment_failed does not set quota_exceeded when under free MAU" do
    @instance.update!(quota_exceeded: false)

    event_data = build_event(
      type: "invoice.payment_failed",
      object: { subscription: @active_sub.subscription_id, customer: @active_sub.customer_id }
    )

    @mock_project_helper.expect(:current_mau, 5000, [@instance])
    StripeService.handle_webhook(event_data)

    @active_sub.reload
    assert_not @active_sub.active
    assert_equal "payment_failed", @active_sub.status

    @instance.reload
    assert_not @instance.quota_exceeded
    @mock_project_helper.verify
  end

  test "invoice.payment_failed does nothing when customer not found" do
    event_data = build_event(
      type: "invoice.payment_failed",
      object: { subscription: "sub_ghost", customer: "cus_ghost" }
    )

    # Should not crash when no subscription matches customer_id
    assert_nothing_raised { StripeService.handle_webhook(event_data) }
  end

  # ============================================================
  # customer.subscription.updated → handle_subscription_updated
  # ============================================================

  test "subscription.updated with cancel_at_period_end true sets cancels_at from timestamp" do
    cancel_time = Time.now + 30.days

    event_data = build_event(
      type: "customer.subscription.updated",
      object: {
        id: @active_sub.subscription_id, customer: @active_sub.customer_id,
        cancel_at: cancel_time.to_i, cancel_at_period_end: true,
        canceled_at: nil, trial_end: nil, status: "active", pause_collection: nil
      }
    )

    @mock_project_helper.expect(:current_mau, 5000, [@instance])
    StripeService.handle_webhook(event_data)

    @active_sub.reload
    assert_not @active_sub.active
    assert_equal "canceled", @active_sub.status
    expected_time = Time.at(cancel_time.to_i).to_datetime
    assert_in_delta expected_time.to_f, @active_sub.cancels_at.to_f, 1.0
    @mock_project_helper.verify
  end

  test "subscription.updated with canceled_at (immediate cancel) sets cancels_at to now" do
    event_data = build_event(
      type: "customer.subscription.updated",
      object: {
        id: @active_sub.subscription_id, customer: @active_sub.customer_id,
        cancel_at: nil, cancel_at_period_end: false,
        canceled_at: Time.now.to_i, trial_end: nil, status: "canceled", pause_collection: nil
      }
    )

    @mock_project_helper.expect(:current_mau, 5000, [@instance])
    before_time = DateTime.now
    StripeService.handle_webhook(event_data)

    @active_sub.reload
    assert_equal "canceled", @active_sub.status
    assert_not_nil @active_sub.cancels_at
    assert_in_delta before_time.to_f, @active_sub.cancels_at.to_f, 5.0
    @mock_project_helper.verify
  end

  test "subscription.updated with pause_collection pauses subscription" do
    event_data = build_event(
      type: "customer.subscription.updated",
      object: {
        id: @active_sub.subscription_id, customer: @active_sub.customer_id,
        cancel_at: nil, cancel_at_period_end: false, canceled_at: nil,
        trial_end: nil, status: "active", pause_collection: { behavior: "void" }
      }
    )

    @mock_project_helper.expect(:current_mau, 5000, [@instance])
    StripeService.handle_webhook(event_data)

    @active_sub.reload
    assert_not @active_sub.active
    assert_equal "paused", @active_sub.status
    @mock_project_helper.verify
  end

  test "subscription.updated with trialing sets active and trialing status" do
    trial_end_time = (Time.now + 14.days).to_i

    event_data = build_event(
      type: "customer.subscription.updated",
      object: {
        id: @active_sub.subscription_id, customer: @active_sub.customer_id,
        cancel_at: nil, cancel_at_period_end: false, canceled_at: nil,
        trial_end: trial_end_time, status: "trialing", pause_collection: nil
      }
    )

    StripeService.handle_webhook(event_data)

    @active_sub.reload
    assert @active_sub.active
    assert_equal "trialing", @active_sub.status

    @instance.reload
    assert_not @instance.quota_exceeded
  end

  test "subscription.updated with no cancel/pause/trial reactivates to active" do
    # Deactivate first
    @active_sub.update!(active: false, status: "paused")

    event_data = build_event(
      type: "customer.subscription.updated",
      object: {
        id: @active_sub.subscription_id, customer: @active_sub.customer_id,
        cancel_at: nil, cancel_at_period_end: false, canceled_at: nil,
        trial_end: nil, status: "active", pause_collection: nil
      }
    )

    StripeService.handle_webhook(event_data)

    @active_sub.reload
    assert @active_sub.active
    assert_equal "active", @active_sub.status

    @instance.reload
    assert_not @instance.quota_exceeded
  end

  test "subscription.updated does nothing when subscription not found" do
    event_data = build_event(
      type: "customer.subscription.updated",
      object: {
        id: "sub_nonexistent", customer: "cus_x",
        cancel_at: nil, cancel_at_period_end: false, canceled_at: nil,
        trial_end: nil, status: "active", pause_collection: nil
      }
    )

    assert_nothing_raised { StripeService.handle_webhook(event_data) }
  end

  # ============================================================
  # customer.subscription.deleted
  # ============================================================

  test "subscription.deleted deactivates subscription" do
    event_data = build_event(
      type: "customer.subscription.deleted",
      object: {
        id: @active_sub.subscription_id, customer: @active_sub.customer_id,
        cancel_at: nil, cancel_at_period_end: false,
        canceled_at: Time.now.to_i, trial_end: nil, status: "canceled", pause_collection: nil
      }
    )

    @mock_project_helper.expect(:current_mau, 5000, [@instance])
    StripeService.handle_webhook(event_data)

    @active_sub.reload
    assert_not @active_sub.active
    assert_equal "canceled", @active_sub.status
    @mock_project_helper.verify
  end

  # ============================================================
  # mark_project_enabled — boundary testing
  # ============================================================

  test "mark_project_enabled at exactly FREE_MAU_COUNT does not set quota_exceeded" do
    # Boundary: current_mau == 10000 (FREE_MAU_COUNT), should NOT exceed (uses >)
    @instance.update!(quota_exceeded: false)

    event_data = build_event(
      type: "invoice.payment_failed",
      object: { subscription: @active_sub.subscription_id, customer: @active_sub.customer_id }
    )

    @mock_project_helper.expect(:current_mau, 10000, [@instance])
    StripeService.handle_webhook(event_data)

    @instance.reload
    assert_not @instance.quota_exceeded, "At exactly FREE_MAU_COUNT, quota_exceeded should be false"
    @mock_project_helper.verify
  end

  test "mark_project_enabled at FREE_MAU_COUNT + 1 sets quota_exceeded" do
    @instance.update!(quota_exceeded: false)

    event_data = build_event(
      type: "invoice.payment_failed",
      object: { subscription: @active_sub.subscription_id, customer: @active_sub.customer_id }
    )

    @mock_project_helper.expect(:current_mau, 10001, [@instance])
    StripeService.handle_webhook(event_data)

    @instance.reload
    assert @instance.quota_exceeded, "At FREE_MAU_COUNT + 1, quota_exceeded should be true"
    @mock_project_helper.verify
  end

  # ============================================================
  # generate_portal_link
  # ============================================================

  test "generate_portal_link returns nil when no subscription exists" do
    instance_two = instances(:two)
    StripeSubscription.where(instance_id: instance_two.id).delete_all

    assert_nil StripeService.generate_portal_link(instance_two)
  end

  test "generate_portal_link calls Stripe with correct customer_id and returns URL" do
    portal_url = "https://billing.stripe.com/p/session/test_abc"
    received_params = nil

    fake_create = lambda { |params|
      received_params = params
      OpenStruct.new(url: portal_url)
    }

    Stripe::BillingPortal::Session.stub(:create, fake_create) do
      result = StripeService.generate_portal_link(@instance)
      assert_equal portal_url, result
      assert_equal @active_sub.customer_id, received_params[:customer]
    end
  end

  # ============================================================
  # cancel_subscription
  # ============================================================

  test "cancel_subscription calls Stripe::Subscription.cancel with correct ID" do
    canceled_sub_id = nil

    fake_cancel = lambda { |sub_id|
      canceled_sub_id = sub_id
      OpenStruct.new(id: sub_id, status: "canceled")
    }

    Stripe::Subscription.stub(:cancel, fake_cancel) do
      StripeService.cancel_subscription(@active_sub)
      assert_equal @active_sub.subscription_id, canceled_sub_id
    end
  end

  test "cancel_subscription swallows StripeError without raising" do
    fake_cancel = ->(_) { raise Stripe::StripeError, "No such subscription" }

    Stripe::Subscription.stub(:cancel, fake_cancel) do
      assert_nothing_raised { StripeService.cancel_subscription(@active_sub) }
    end
  end

  # ============================================================
  # pause_subscription / resume_subscription
  # These are thin wrappers over Stripe API — we verify the correct
  # subscription_id and params are forwarded, not Stripe's behavior.
  # ============================================================

  test "pause_subscription calls Stripe::Subscription.update with pause_collection" do
    received_args = nil

    fake_update = lambda { |sub_id, params|
      received_args = { sub_id: sub_id, params: params }
      OpenStruct.new(id: sub_id)
    }

    Stripe::Subscription.stub(:update, fake_update) do
      StripeService.pause_subscription(@active_sub)

      assert_equal @active_sub.subscription_id, received_args[:sub_id]
      assert_equal({ behavior: "void" }, received_args[:params][:pause_collection])
    end
  end

  test "resume_subscription calls Stripe::Subscription.update to clear pause_collection" do
    received_args = nil

    fake_update = lambda { |sub_id, params|
      received_args = { sub_id: sub_id, params: params }
      OpenStruct.new(id: sub_id)
    }

    Stripe::Subscription.stub(:update, fake_update) do
      StripeService.resume_subscription(@active_sub)

      assert_equal @active_sub.subscription_id, received_args[:sub_id]
      assert_equal "", received_args[:params][:pause_collection]
    end
  end

  # ============================================================
  # create_checkout_session_for_product
  # ============================================================

  test "create_checkout_session_for_product creates session and payment intent" do
    user = users(:admin_user)
    received_params = nil

    fake_session = OpenStruct.new(id: "cs_test_session_123")
    fake_create = lambda { |params|
      received_params = params
      fake_session
    }

    Stripe::Checkout::Session.stub(:create, fake_create) do
      result = StripeService.create_checkout_session_for_product("price_test_123", user, "pro", @instance)

      assert_equal fake_session, result
      assert_equal "subscription", received_params[:mode]
      assert_equal user.email, received_params[:customer_email]
      assert_equal @instance.id.to_s, received_params[:client_reference_id]
      assert_equal "price_test_123", received_params[:line_items][0][:price]
    end

    # Verify payment intent was created
    pi = StripePaymentIntent.find_by(intent_id: "cs_test_session_123")
    assert_not_nil pi
    assert_equal "pro", pi.product_type
    assert_equal @instance.id, pi.instance_id
    assert_equal user.id, pi.user_id
  end

  # ============================================================
  # apply_discounts — threshold routing
  # ============================================================

  test "apply_discounts removes coupon when quantity below free MAU count" do
    discount_deleted = false

    Stripe::Subscription.stub(:delete_discount, ->(_sub_id) { discount_deleted = true }) do
      StripeService.send(:apply_discounts, @active_sub, 5000)
    end

    assert discount_deleted, "Should remove coupon when under free threshold"
  end

  test "apply_discounts applies $19.99 coupon when quantity at free MAU threshold" do
    coupon_created_params = nil
    coupon_applied = false

    fake_coupon = OpenStruct.new(id: "coupon_1999")

    Stripe::Subscription.stub(:delete_discount, ->(_) { nil }) do
      Stripe::Coupon.stub(:create, lambda { |params| 
        coupon_created_params = params
        fake_coupon
      }) do
        Stripe::Subscription.stub(:update, ->(_sub_id, _params) { coupon_applied = true }) do
          StripeService.send(:apply_discounts, @active_sub, 10000)
        end
      end
    end

    assert_not_nil coupon_created_params
    assert_equal 1999, coupon_created_params[:amount_off], "Should create $19.99 coupon (1999 cents)"
    assert coupon_applied
  end

  test "apply_discounts applies first discount percentage when quantity above first threshold" do
    coupon_created_params = nil

    fake_coupon = OpenStruct.new(id: "coupon_10pct")

    Stripe::Subscription.stub(:delete_discount, ->(_) { nil }) do
      Stripe::Coupon.stub(:create, lambda { |params| 
        coupon_created_params = params
        fake_coupon
      }) do
        Stripe::Subscription.stub(:update, ->(_sub_id, _params) { nil }) do
          StripeService.send(:apply_discounts, @active_sub, 50000)
        end
      end
    end

    assert_not_nil coupon_created_params
    assert_equal 10, coupon_created_params[:percent_off]
  end

  test "apply_discounts applies second discount percentage when quantity above second threshold" do
    coupon_created_params = nil

    fake_coupon = OpenStruct.new(id: "coupon_20pct")

    Stripe::Subscription.stub(:delete_discount, ->(_) { nil }) do
      Stripe::Coupon.stub(:create, lambda { |params| 
        coupon_created_params = params
        fake_coupon
      }) do
        Stripe::Subscription.stub(:update, ->(_sub_id, _params) { nil }) do
          StripeService.send(:apply_discounts, @active_sub, 100000)
        end
      end
    end

    assert_not_nil coupon_created_params
    assert_equal 20, coupon_created_params[:percent_off]
  end

  # ============================================================
  # set_usage
  # ============================================================

  test "set_usage returns early when instance has no subscription" do
    instance_two = instances(:two)
    StripeSubscription.where(instance_id: instance_two.id).delete_all

    # Should not call any Stripe APIs
    assert_nothing_raised { StripeService.set_usage(instance_two) }
  end

  test "set_usage computes MAU and creates usage record" do
    @active_sub.update!(subscription_item_id: "si_test_item")

    # Instance needs both test and production projects for compute_mau_for_dates
    Project.find_or_create_by!(instance: @instance, test: true) do |p|
      p.name = "Test Project"
      p.identifier = "test-project-stripe-test"
    end

    fake_subscription = OpenStruct.new(
      current_period_start: (Time.now - 30.days).to_i,
      current_period_end: Time.now.to_i
    )

    received_usage_params = nil

    Stripe::Subscription.stub(:retrieve, ->(_) { fake_subscription }) do
      Stripe::SubscriptionItem.stub(:create_usage_record, lambda { |item_id, params|
        received_usage_params = { item_id: item_id, params: params }
        OpenStruct.new
      }) do
        StripeService.stub(:apply_discounts, nil) do
          StripeService.set_usage(@instance)
        end
      end
    end

    assert_not_nil received_usage_params
    assert_equal "si_test_item", received_usage_params[:item_id]
    assert_equal "set", received_usage_params[:params][:action]
    assert received_usage_params[:params][:quantity].is_a?(Integer)
  end

  test "set_usage swallows StripeError without raising" do
    @active_sub.update!(subscription_item_id: "si_test_item")

    Stripe::Subscription.stub(:retrieve, ->(_) { raise Stripe::StripeError, "API error" }) do
      assert_nothing_raised { StripeService.set_usage(@instance) }
    end
  end
end
