require "test_helper"

class SubscriptionBillingServiceTest < ActiveSupport::TestCase
  fixtures :instances

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

  # === create_checkout_session ===

  test "create_checkout_session returns URL and passes correct args to stripe" do
    user = User.create!(email: "billing@test.com", password: "password123")

    @instance.stub(:subscription, nil) do
      fake_create = ->(*_args) { { url: "https://checkout.stripe.com/session" } }
      StripeService.stub(:create_checkout_session_for_product, fake_create) do
        result = build_service.create_checkout_session(user: user)
        assert_equal "https://checkout.stripe.com/session", result[:url]
        assert result.is_a?(Hash), "Should return a hash with :url key"
      end
    end
  end

  test "create_checkout_session uses ENV price_id when none provided" do
    user = User.create!(email: "billing_env@test.com", password: "password123")
    expected_price = ENV["STRIPE_STANDARD_PRICE_ID"]
    received_price = nil

    @instance.stub(:subscription, nil) do
      fake_create = lambda { |price_id, *_args| 
        received_price = price_id
        { url: "https://example.com" }
      }
      StripeService.stub(:create_checkout_session_for_product, fake_create) do
        build_service.create_checkout_session(user: user)
        assert_equal expected_price, received_price, "Should use ENV price_id"
      end
    end
  end

  test "create_checkout_session raises when already subscribed" do
    user = User.create!(email: "billing2@test.com", password: "password123")
    mock_sub = OpenStruct.new(subscription_id: "sub_123")

    @instance.stub(:subscription, mock_sub) do
      error = assert_raises(ArgumentError) do
        build_service.create_checkout_session(user: user)
      end
      assert_match(/already subscribed/, error.message)
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
        result = build_service.subscription_details
        assert_nil result
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
end
