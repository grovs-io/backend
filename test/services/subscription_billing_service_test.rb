require "test_helper"

class SubscriptionBillingServiceTest < ActiveSupport::TestCase
  fixtures :instances, :stripe_subscriptions, :stripe_payment_intents

  setup do
    @instance = instances(:one)
    @project_service = Minitest::Mock.new
  end

  def build_service(instance: @instance)
    SubscriptionBillingService.new(
      instance: instance,
      project_service: @project_service
    )
  end

  def flat_sub(product_type: "growth_250k", cancels_at: nil)
    OpenStruct.new(subscription_id: "sub_flat", product_type: product_type, active: true, status: "active", cancels_at: cancels_at)
  end

  def remote_flat(interval:, latest_invoice: nil)
    Stripe::Subscription.construct_from(
      id: "sub_flat", current_period_start: 1_700_000_000, current_period_end: 1_731_536_000,
      items: { data: [{ price: { id: "price_x", recurring: { interval: interval } } }] },
      latest_invoice: latest_invoice
    )
  end

  # flexible billing_mode subscriptions carry no top-level period — only on the item
  def remote_flat_flexible(interval:)
    Stripe::Subscription.construct_from(
      id: "sub_flat",
      items: { data: [{ price: { id: "price_x", recurring: { interval: interval } },
                        current_period_start: 1_700_000_000, current_period_end: 1_731_536_000 }] }
    )
  end

  def paid_invoice(**overrides)
    {
      id: "in_1", number: "GRV-0001", invoice_pdf: "https://pay.stripe.com/invoice/pdf", hosted_invoice_url: "https://invoice.stripe.com/i/1",
      amount_paid: 4900, status: "paid", status_transitions: { paid_at: 1_700_000_100 },
      customer_name: "Acme Ltd", customer_tax_ids: [{ type: "eu_vat", value: "RO123" }, { type: "eu_vat", value: "RO999" }],
      customer_address: { line1: "1 Main St", line2: "Floor 2", postal_code: "010101", city: "Bucharest", country: "RO", state: nil }
    }.merge(overrides)
  end

  def flat_details_with(remote)
    @project_service.expect(:current_mau, 1, [@instance])
    received = nil
    fetch = lambda { |id, **opts|
      received = [id, opts]
      remote
    }
    result = @instance.stub(:subscription, flat_sub) do
      StripeService.stub(:get_subscription_details, fetch) do
        StripeService.stub(:upcoming_invoice_or_nil, nil) { build_service.subscription_details }
      end
    end
    [result, received]
  end

  # === create_checkout_session ===

  test "create_checkout_session returns only the embedded client secret" do
    user = User.create!(email: "billing@test.com", password: "password123")
    StripeSubscription.where(instance: @instance).delete_all

    @instance.stub(:subscription, nil) do
      StripeService.stub(:expire_open_checkout_sessions, nil) do
        fake_create = ->(*_args) { Stripe::Checkout::Session.construct_from(id: "cs_1", client_secret: "cs_1_secret_x", url: nil) }
        StripeService.stub(:create_checkout_session_for_product, fake_create) do
          result = build_service.create_checkout_session(user: user, plan: "growth_250k", interval: "monthly")
          assert_equal({ client_secret: "cs_1_secret_x" }, result)
        end
      end
    end
  end

  test "create_checkout_session raises when already subscribed" do
    user = User.create!(email: "billing2@test.com", password: "password123")
    instance = Instance.create!(uri_scheme: "sub#{SecureRandom.hex(4)}", api_key: SecureRandom.hex(16))
    intent = StripePaymentIntent.create!(instance: instance, user: user, intent_id: "cs_#{SecureRandom.hex(4)}", product_type: "growth_250k")
    StripeSubscription.create!(instance: instance, stripe_payment_intent: intent, subscription_id: "sub_123",
                               customer_id: "cus_123", active: true, status: "active", product_type: "growth_250k")

    error = assert_raises(ArgumentError) do
      build_service(instance: instance).create_checkout_session(user: user, plan: "growth_250k", interval: "monthly")
    end
    assert_match(/already subscribed/, error.message)
  end

  test "create_checkout_session sends the catalog price and the plan key" do
    user = User.create!(email: "billing_plan@test.com", password: "password123")
    received = nil
    fake_create = lambda { |price_id, _user, product_type, _instance| 
      received = [price_id, product_type]
      { client_secret: "secret" }
    }
    StripeSubscription.where(instance: @instance).delete_all

    @instance.stub(:subscription, nil) do
      StripeService.stub(:expire_open_checkout_sessions, nil) do
        StripeService.stub(:create_checkout_session_for_product, fake_create) do
          build_service.create_checkout_session(user: user, plan: "scale_1m", interval: "yearly")
        end
      end
    end

    assert_equal ["price_test_s1m_y", "scale_1m"], received
  end

  test "create_checkout_session refuses an instance with a valid enterprise subscription" do
    user = User.create!(email: "billing_ent@test.com", password: "password123")
    instance = Instance.create!(uri_scheme: "ent#{SecureRandom.hex(4)}", api_key: SecureRandom.hex(16))
    EnterpriseSubscription.create!(instance_id: instance.id, start_date: 1.day.ago, end_date: 1.year.from_now, total_maus: 1_000_000, active: true)

    error = assert_raises(ArgumentError) do
      build_service(instance: instance).create_checkout_session(user: user, plan: "growth_250k", interval: "monthly")
    end
    assert_match(/already subscribed/, error.message)
  end

  test "create_checkout_session refuses while any earlier subscription is unresolved, at any age" do
    user = User.create!(email: "billing_unresolved@test.com", password: "password123")
    %w[pending payment_failed past_due incomplete unpaid].each do |status|
      instance = Instance.create!(uri_scheme: "unres#{SecureRandom.hex(4)}", api_key: SecureRandom.hex(16))
      intent = StripePaymentIntent.create!(instance: instance, user: user, intent_id: "cs_#{SecureRandom.hex(4)}", product_type: "growth_250k", 
created_at: 3.days.ago)
      StripeSubscription.create!(instance: instance, stripe_payment_intent: intent, subscription_id: "sub_#{SecureRandom.hex(4)}",
                                 customer_id: "cus_u", active: false, status: status, product_type: "growth_250k", created_at: 3.days.ago)

      StripeService.stub(:expire_open_checkout_sessions, ->(_) { flunk "must refuse before touching Stripe" }) do
        error = assert_raises(ArgumentError, status) do
          build_service(instance: instance).create_checkout_session(user: user, plan: "growth_250k", interval: "monthly")
        end
        assert_match(/already subscribed/, error.message)
      end
    end
  end

  test "create_checkout_session refuses while an active row has a NULL status" do
    user = User.create!(email: "billing_nullstatus@test.com", password: "password123")
    instance = Instance.create!(uri_scheme: "nullst#{SecureRandom.hex(4)}", api_key: SecureRandom.hex(16))
    intent = StripePaymentIntent.create!(instance: instance, user: user, intent_id: "cs_#{SecureRandom.hex(4)}", product_type: "growth_250k")
    subscription = StripeSubscription.create!(instance: instance, stripe_payment_intent: intent, subscription_id: "sub_#{SecureRandom.hex(4)}",
                                               customer_id: "cus_null", active: true, status: "active", product_type: "growth_250k")
    subscription.update_column(:status, nil)

    StripeService.stub(:expire_open_checkout_sessions, ->(_) { flunk "must refuse before touching Stripe" }) do
      error = assert_raises(ArgumentError) do
        build_service(instance: instance).create_checkout_session(user: user, plan: "growth_250k", interval: "monthly")
      end
      assert_match(/already subscribed/, error.message)
    end
  end

  test "create_checkout_session allows a new plan after the old one ended" do
    user = User.create!(email: "billing_ended@test.com", password: "password123")
    instance = Instance.create!(uri_scheme: "ended#{SecureRandom.hex(4)}", api_key: SecureRandom.hex(16))
    %w[canceled incomplete_expired].each do |status|
      intent = StripePaymentIntent.create!(instance: instance, user: user, intent_id: "cs_#{SecureRandom.hex(4)}", product_type: "growth_250k")
      StripeSubscription.create!(instance: instance, stripe_payment_intent: intent, subscription_id: "sub_#{SecureRandom.hex(4)}",
                                 customer_id: "cus_e", active: false, status: status, product_type: "growth_250k")
    end

    StripeService.stub(:expire_open_checkout_sessions, nil) do
      StripeService.stub(:create_checkout_session_for_product, ->(*) { { client_secret: "secret" } }) do
        assert_equal "secret", build_service(instance: instance).create_checkout_session(user: user, plan: "growth_250k", interval: "monthly")[:client_secret]
      end
    end
  end

  test "create_checkout_session refuses while an earlier session is already paid" do
    user = User.create!(email: "billing_paid@test.com", password: "password123")
    StripeSubscription.where(instance: @instance).delete_all
    @instance.stub(:subscription, nil) do
      StripeService.stub(:expire_open_checkout_sessions, ->(_) { raise StripeService::CheckoutAlreadyCompleted }) do
        assert_raises(StripeService::CheckoutAlreadyCompleted) do
          build_service.create_checkout_session(user: user, plan: "growth_250k", interval: "monthly")
        end
      end
    end
  end

  # === portal_url ===

  test "portal_url returns hash with URL from stripe" do
    StripeService.stub(:generate_portal_link, "https://billing.stripe.com/portal") do
      result = build_service.portal_url
      assert_equal({ url: "https://billing.stripe.com/portal" }, result)
    end
  end

  # === cancel_subscription ===

  test "cancel_subscription forwards to stripe helper and returns result" do
    mock_sub = OpenStruct.new(subscription_id: "sub_123")

    @instance.stub(:subscription, mock_sub) do
      StripeService.stub(:cancel_subscription, { canceled: true }) do
        result = build_service.cancel_subscription
        assert_equal({ canceled: true }, result)
      end
    end
  end

  test "cancel_subscription returns nil without subscription" do
    @instance.stub(:subscription, nil) do
      result = build_service.cancel_subscription
      assert_nil result
    end
  end

  test "cancel_subscription applies the returned subscription immediately for a flat plan" do
    sub = stripe_subscriptions(:active_sub)
    sub.update!(product_type: "growth_250k", cancels_at: nil)
    cancel_at = 20.days.from_now.to_i
    remote = Stripe::Subscription.construct_from(id: sub.subscription_id, status: "active", cancel_at: cancel_at)

    @instance.stub(:subscription, sub) do
      StripeService.stub(:cancel_subscription, remote) do
        result = build_service.cancel_subscription
        assert_equal remote, result
      end
    end
    # Applied immediately, not left to wait for the webhook.
    assert_in_delta cancel_at, sub.reload.cancels_at.to_i, 1
  end

  test "cancel_subscription does not apply when Stripe returns false" do
    sub = stripe_subscriptions(:active_sub)
    sub.update!(product_type: "growth_250k", cancels_at: nil)

    @instance.stub(:subscription, sub) do
      StripeService.stub(:cancel_subscription, false) do
        result = build_service.cancel_subscription
        assert_equal false, result
      end
    end
    assert_nil sub.reload.cancels_at
  end

  # === resume_subscription ===

  test "resume_subscription forwards to stripe helper for any flat subscription, cancels_at or not" do
    mock_sub = flat_sub(cancels_at: nil)

    @instance.stub(:subscription, mock_sub) do
      StripeService.stub(:resume_cancellation, { resumed: true }) do
        StripeService.stub(:apply_flat_subscription, nil) do
          result = build_service.resume_subscription
          assert_equal({ resumed: true }, result)
        end
      end
    end
  end

  test "resume_subscription applies the returned subscription immediately" do
    sub = stripe_subscriptions(:active_sub)
    sub.update!(product_type: "growth_250k", cancels_at: 10.days.from_now)
    remote = Stripe::Subscription.construct_from(id: sub.subscription_id, status: "active", cancel_at: nil)

    @instance.stub(:subscription, sub) do
      StripeService.stub(:resume_cancellation, remote) do
        result = build_service.resume_subscription
        assert_equal remote, result
      end
    end
    assert_nil sub.reload.cancels_at
  end

  test "resume_subscription returns nil without subscription" do
    @instance.stub(:subscription, nil) do
      result = build_service.resume_subscription
      assert_nil result
    end
  end

  test "resume_subscription returns nil when not flat" do
    mock_sub = OpenStruct.new(subscription_id: "sub_123", product_type: "pro", cancels_at: Time.now)

    @instance.stub(:subscription, mock_sub) do
      result = build_service.resume_subscription
      assert_nil result
    end
  end

  # === subscription_details ===

  test "subscription_details returns complete stripe details structure" do
    mock_sub = OpenStruct.new(subscription_id: "sub_123", active: true, status: "active")
    snapshot = {
      amount_cents: 9900,
      amount_formatted: "$99.00",
      maus_from_invoice_line: 15000,
      period_start: Date.today - 30,
      period_end: Date.today,
      next_payment_attempt: Date.today + 1
    }
    @project_service.expect(:compute_maus_per_month_total, 5000, [@instance, Date.today - 30, Date.today])

    @instance.stub(:subscription, mock_sub) do
      StripeService.stub(:get_subscription_details, { plan: "pro" }) do
        StripeService.stub(:get_billing_cycle, { start: Date.today - 30, end: Date.today }) do
          StripeService.stub(:monthly_total_snapshot, snapshot) do
            result = build_service.subscription_details

            assert_equal "stripe", result[:type]
            assert result[:details][:active]
            assert_not result[:details][:paused]
            assert_equal 9900, result[:amount_cents]
            assert_equal "$99.00", result[:amount_formatted]
            assert result.key?(:stripe_subscription)
            assert result.key?(:quantity_for_current_billing_cycle)
            assert result.key?(:maus)
            assert result.key?(:period_start)
            assert result.key?(:period_end)
            assert result.key?(:next_payment_attempt)

            free_maus = ENV.fetch("FREE_MAU_COUNT", "10000").to_i
            expected_paid = free_maus < 15000 ? 15000 - free_maus : 0
            assert_equal expected_paid, result[:quantity_for_current_billing_cycle]

            @project_service.verify
          end
        end
      end
    end
  end

  test "subscription_details marks paused subscription correctly" do
    mock_sub = OpenStruct.new(subscription_id: "sub_paused", active: true, status: "paused")

    @instance.stub(:subscription, mock_sub) do
      StripeService.stub(:get_subscription_details, {}) do
        StripeService.stub(:get_billing_cycle, nil) do
          StripeService.stub(:monthly_total_snapshot, nil) do
            result = build_service.subscription_details
            assert result[:details][:paused], "Paused subscription should be marked as paused"
            assert_equal 0, result[:quantity_for_current_billing_cycle], "No billing cycle should mean 0 MAUs"
          end
        end
      end
    end
  end

  test "subscription_details returns complete enterprise structure" do
    enterprise = OpenStruct.new(
      start_date: Date.today - 30,
      end_date: Date.today + 335,
      total_maus: 100_000,
      active: true
    )
    @project_service.expect(:compute_maus_per_month_total, 25000, [@instance, enterprise.start_date, DateTime])

    @instance.stub(:subscription, nil) do
      @instance.stub(:valid_enterprise_subscription, enterprise) do
        result = build_service.subscription_details
        assert_equal "enterprise", result[:type]
        assert_equal 100_000, result[:total_maus]
        assert_equal 25000, result[:current_maus]
        assert_equal enterprise.start_date, result[:start_at]
        assert_equal enterprise.end_date, result[:end_at]
        @project_service.verify
      end
    end
  end

  test "subscription_details returns nil without any subscription" do
    @instance.stub(:subscription, nil) do
      @instance.stub(:valid_enterprise_subscription, nil) do
        @instance.stub(:unresolved_subscription, nil) do
          result = build_service.subscription_details
          assert_nil result
        end
      end
    end
  end

  test "subscription_details returns payment_issue for a past_due-only instance" do
    unresolved = OpenStruct.new(status: "past_due", product_type: "growth_250k")
    @instance.stub(:subscription, nil) do
      @instance.stub(:valid_enterprise_subscription, nil) do
        @instance.stub(:unresolved_subscription, unresolved) do
          result = build_service.subscription_details
          assert_equal({ type: "stripe", payment_issue: true, status: "past_due", plan: "growth_250k" }, result)
        end
      end
    end
  end

  test "subscription_details payment_issue plan is nil for a legacy (non-flat) product" do
    unresolved = OpenStruct.new(status: "incomplete", product_type: "pro")
    @instance.stub(:subscription, nil) do
      @instance.stub(:valid_enterprise_subscription, nil) do
        @instance.stub(:unresolved_subscription, unresolved) do
          result = build_service.subscription_details
          assert_equal({ type: "stripe", payment_issue: true, status: "incomplete", plan: nil }, result)
        end
      end
    end
  end

  test "subscription_details prefers enterprise over an unresolved subscription" do
    enterprise = OpenStruct.new(start_date: Date.today, end_date: Date.today + 365, total_maus: 50000, active: true)
    unresolved = OpenStruct.new(status: "past_due", product_type: "growth_250k")
    @project_service.expect(:compute_maus_per_month_total, 1000, [@instance, enterprise.start_date, DateTime])

    @instance.stub(:subscription, nil) do
      @instance.stub(:valid_enterprise_subscription, enterprise) do
        @instance.stub(:unresolved_subscription, unresolved) do
          result = build_service.subscription_details
          assert_equal "enterprise", result[:type]
          @project_service.verify
        end
      end
    end
  end

  test "subscription_details checks stripe before enterprise" do
    mock_sub = OpenStruct.new(subscription_id: "sub_first", active: true, status: "active")
    enterprise = OpenStruct.new(start_date: Date.today, end_date: Date.today + 365, total_maus: 50000, active: true)

    @instance.stub(:subscription, mock_sub) do
      @instance.stub(:valid_enterprise_subscription, enterprise) do
        StripeService.stub(:get_subscription_details, {}) do
          StripeService.stub(:get_billing_cycle, nil) do
            StripeService.stub(:monthly_total_snapshot, nil) do
              result = build_service.subscription_details
              assert_equal "stripe", result[:type], "Stripe should take priority over enterprise"
            end
          end
        end
      end
    end
  end

  # === current_mau ===

  test "current_mau returns count and total_available from ENV" do
    @project_service.expect(:current_mau, 7500, [@instance])

    result = build_service.current_mau
    assert_equal 7500, result[:current_quantity]
    assert_equal ENV["FREE_MAU_COUNT"], result[:total_available]
    @project_service.verify
  end

  # === current_usage ===

  test "current_usage returns stripe usage with all fields" do
    mock_sub = OpenStruct.new(subscription_id: "sub_123", active: true)

    @instance.stub(:subscription, mock_sub) do
      StripeService.stub(:get_subscription_details, { start_date: Date.today - 30 }) do
        StripeService.stub(:get_next_invoice, { total: 9900, next_payment_attempt: Date.today + 1 }) do
          StripeService.stub(:get_usage, { data: [{ total_usage: 12000 }] }) do
            result = build_service.current_usage
            assert_equal 9900, result[:amount]
            assert_equal 12000, result[:maus]
            assert_equal Date.today + 1, result[:next_payment_attempt]
            assert_equal Date.today - 30, result[:start_date]
          end
        end
      end
    end
  end

  test "current_usage returns enterprise usage with complete structure" do
    enterprise = OpenStruct.new(
      start_date: Date.today - 30,
      end_date: Date.today + 335,
      total_maus: 100_000,
      active: true
    )
    @project_service.expect(:compute_maus_per_month_total, 25000, [@instance, enterprise.start_date, DateTime])

    @instance.stub(:subscription, nil) do
      @instance.stub(:valid_enterprise_subscription, enterprise) do
        result = build_service.current_usage
        assert_equal "enterprise", result[:type]
        assert_equal 25000, result[:current_maus]
        assert_equal 100_000, result[:total_maus]
        assert_equal enterprise.start_date, result[:start_at]
        assert_equal enterprise.end_date, result[:end_at]
        @project_service.verify
      end
    end
  end

  test "current_usage skips inactive stripe subscription" do
    mock_sub = OpenStruct.new(subscription_id: "sub_inactive", active: false)

    @instance.stub(:subscription, mock_sub) do
      @instance.stub(:valid_enterprise_subscription, nil) do
        result = build_service.current_usage
        assert_nil result, "Inactive stripe subscription should not return usage"
      end
    end
  end

  test "current_usage returns nil without subscription" do
    @instance.stub(:subscription, nil) do
      @instance.stub(:valid_enterprise_subscription, nil) do
        result = build_service.current_usage
        assert_nil result
      end
    end
  end

  test "flat yearly subscription_details uses this month's MAU, not the billing-period sum" do
    @project_service.expect(:current_mau, 100_000, [@instance])
    invoice = OpenStruct.new(total: 250_000, next_payment_attempt: 1_731_536_000)

    @instance.stub(:subscription, flat_sub) do
      StripeService.stub(:get_subscription_details, remote_flat(interval: "year")) do
        StripeService.stub(:upcoming_invoice_or_nil, invoice) do
          StripeService.stub(:get_usage, ->(*) { flunk "metered-only call" }) do
            result = build_service.subscription_details
            assert_equal "growth_250k", result[:plan]
            assert_equal "yearly", result[:interval]
            assert_equal 250_000, result[:mau_cap]
            assert_equal 100_000, result[:maus]
            assert_equal 250_000, result[:amount_cents]
            assert_equal 1_700_000_000, result[:stripe_subscription][:current_period_start]
          end
        end
      end
    end
    @project_service.verify
  end

  test "flat details with a pending cancel return nil next invoice and cancels_at" do
    @project_service.expect(:current_mau, 5, [@instance])
    ends = 20.days.from_now
    @instance.stub(:subscription, flat_sub(cancels_at: ends)) do
      StripeService.stub(:get_subscription_details, remote_flat(interval: "month")) do
        StripeService.stub(:upcoming_invoice_or_nil, nil) do
          result = build_service.subscription_details
          assert_nil result[:amount_cents]
          assert_nil result[:next_payment_attempt]
          assert_equal ends, result[:cancels_at]
          assert_equal "monthly", result[:interval]
        end
      end
    end
  end

  test "flat current_usage never calls metered usage summaries" do
    @project_service.expect(:current_mau, 7, [@instance])
    @instance.stub(:subscription, flat_sub(product_type: "scale_1m")) do
      StripeService.stub(:get_subscription_details, remote_flat(interval: "month")) do
        StripeService.stub(:upcoming_invoice_or_nil, nil) do
          StripeService.stub(:get_usage, ->(*) { flunk "metered-only call" }) do
            result = build_service.current_usage
            assert_equal 1_000_000, result[:mau_cap]
            assert_equal 7, result[:maus]
          end
        end
      end
    end
  end

  test "flat details expand the latest invoice and map receipt and billed-to fields" do
    result, received = flat_details_with(remote_flat(interval: "month", latest_invoice: paid_invoice))

    assert_equal ["sub_flat", { expand: ["latest_invoice"] }], received
    assert_equal({ number: "GRV-0001", invoice_pdf: "https://pay.stripe.com/invoice/pdf", hosted_invoice_url: "https://invoice.stripe.com/i/1",
                   amount_paid: 4900, status: "paid", paid_at: 1_700_000_100 }, result[:latest_invoice])
    assert_equal({ name: "Acme Ltd", tax_id: "RO123", address_lines: ["1 Main St, Floor 2", "010101 Bucharest", "RO"] }, result[:billed_to])
  end

  test "flat details tolerate a sparse invoice" do
    sparse = paid_invoice(invoice_pdf: nil, status: "open", status_transitions: { paid_at: nil }, customer_name: nil,
                          customer_tax_ids: [], customer_address: { line1: "1 Main St", line2: nil, postal_code: nil, city: "Cluj", country: nil })
    result, = flat_details_with(remote_flat(interval: "month", latest_invoice: sparse))

    assert_nil result[:latest_invoice][:invoice_pdf]
    assert_nil result[:latest_invoice][:paid_at]
    assert_equal({ name: nil, tax_id: nil, address_lines: ["1 Main St", "Cluj"] }, result[:billed_to])
  end

  test "flat details include the state for a US address" do
    us_invoice = paid_invoice(customer_address: { line1: "1 Infinite Loop", line2: nil, postal_code: "95014", city: "Cupertino",
                                                   state: "CA", country: "US" })
    result, = flat_details_with(remote_flat(interval: "month", latest_invoice: us_invoice))

    assert_equal({ name: "Acme Ltd", tax_id: "RO123", address_lines: ["1 Infinite Loop", "95014 Cupertino, CA", "US"] },
                 result[:billed_to])
  end

  test "flat details return nil invoice and billed-to when there is no invoice yet" do
    result, = flat_details_with(remote_flat(interval: "month"))

    assert_nil result[:latest_invoice]
    assert_nil result[:billed_to]
  end

  test "flat details fall back to the item's period when the subscription has none" do
    result, = flat_details_with(remote_flat_flexible(interval: "month"))

    assert_equal 1_700_000_000, result[:period_start]
    assert_equal 1_731_536_000, result[:period_end]
    assert_equal 1_700_000_000, result[:stripe_subscription][:current_period_start]
    assert_equal 1_731_536_000, result[:stripe_subscription][:current_period_end]
  end
end
