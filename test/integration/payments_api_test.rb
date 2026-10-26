require "test_helper"
require_relative "auth_test_helper"

class PaymentsApiTest < ActionDispatch::IntegrationTest
  include AuthTestHelper

  fixtures :instances, :users, :instance_roles, :projects

  setup do
    @instance = instances(:one)
    @admin_user = users(:admin_user)
    @member_user = users(:member_user)
  end

  # --- create_subscription_session ---

  test "create_subscription_session without auth returns 401" do
    post "#{API_PREFIX}/instances/#{@instance.id}/billing/subscriptions",
      headers: api_headers
    assert_response :unauthorized
  end

  test "create_subscription_session as member returns 403" do
    headers = doorkeeper_headers_for(@member_user)
    mock_service = Minitest::Mock.new

    SubscriptionBillingService.stub(:new, ->(**_args) { mock_service }) do
      post "#{API_PREFIX}/instances/#{@instance.id}/billing/subscriptions",
        headers: headers
      assert_response :forbidden
      json = JSON.parse(response.body)
      assert_equal "Forbidden", json["error"]
    end
  end

  test "create_subscription_session as admin returns the checkout client secret" do
    headers = doorkeeper_headers_for(@admin_user)
    mock_service = Minitest::Mock.new
    mock_service.expect(:create_checkout_session, { client_secret: "cs_test_secret_123" },
                         user: @admin_user, plan: "growth_250k", interval: "monthly")

    SubscriptionBillingService.stub(:new, ->(**_args) { mock_service }) do
      post "#{API_PREFIX}/instances/#{@instance.id}/billing/subscriptions",
        headers: headers, params: { plan: "growth_250k", interval: "monthly" }, as: :json
      assert_response :ok
      assert_equal({ "client_secret" => "cs_test_secret_123" }, JSON.parse(response.body))
    end
    mock_service.verify
  end

  test "create_subscription_session with unknown plan returns 422 Unknown plan" do
    headers = doorkeeper_headers_for(@admin_user)
    [{}, { plan: "scale_up", interval: "monthly" }, { plan: "growth_250k", interval: "weekly" }].each do |body|
      post "#{API_PREFIX}/instances/#{@instance.id}/billing/subscriptions", headers: headers, params: body, as: :json
      assert_response :unprocessable_entity
      assert_equal "Unknown plan", JSON.parse(response.body)["error"]
    end
  end

  test "create_subscription_session returns a processing message when checkout already completed" do
    headers = doorkeeper_headers_for(@admin_user)
    service = Object.new
    def service.create_checkout_session(**) = raise(StripeService::CheckoutAlreadyCompleted)

    SubscriptionBillingService.stub(:new, ->(**_args) { service }) do
      post "#{API_PREFIX}/instances/#{@instance.id}/billing/subscriptions", headers: headers,
        params: { plan: "growth_250k", interval: "monthly" }, as: :json
    end
    assert_response :unprocessable_entity
    assert_equal "Your payment is being processed. Refresh in a minute.", JSON.parse(response.body)["error"]
  end

  test "create_subscription_session keeps the already-subscribed message for ArgumentError" do
    headers = doorkeeper_headers_for(@admin_user)
    service = Object.new
    def service.create_checkout_session(**) = raise(ArgumentError)

    SubscriptionBillingService.stub(:new, ->(**_args) { service }) do
      post "#{API_PREFIX}/instances/#{@instance.id}/billing/subscriptions", headers: headers,
        params: { plan: "growth_250k", interval: "monthly" }, as: :json
    end
    assert_response :unprocessable_entity
    assert_equal "This project is already subscribed", JSON.parse(response.body)["error"]
  end

  # --- Self-hosted mode ---

  test "self-hosted mode returns billing-disabled (403) and never touches Stripe" do
    ENV["GROVS_SELF_HOSTED"] = "true"
    headers = doorkeeper_headers_for(@admin_user)
    service_built = false

    SubscriptionBillingService.stub(:new, lambda { |**_args| 
      service_built = true
      Minitest::Mock.new
    }) do
      post "#{API_PREFIX}/instances/#{@instance.id}/billing/subscriptions", headers: headers
    end

    assert_response :forbidden
    assert_equal "Billing is disabled in self-hosted mode", JSON.parse(response.body)["error"]
    assert_not service_built, "must short-circuit before building the Stripe billing service"
  ensure
    ENV.delete("GROVS_SELF_HOSTED")
  end

  # --- subscription_details ---

  test "subscription_details as member with no subscription returns 404" do
    headers = doorkeeper_headers_for(@member_user)
    mock_service = Minitest::Mock.new
    mock_service.expect(:subscription_details, nil)

    SubscriptionBillingService.stub(:new, ->(**_args) { mock_service }) do
      get "#{API_PREFIX}/instances/#{@instance.id}/billing/subscription",
        headers: headers
      assert_response :not_found
      json = JSON.parse(response.body)
      assert_equal "No active subscriptions", json["error"]
    end
    mock_service.verify
  end

  test "subscription_details as member with active subscription returns 200" do
    headers = doorkeeper_headers_for(@member_user)
    sub_data = { plan: "standard", status: "active", mau_limit: 10_000 }
    mock_service = Minitest::Mock.new
    mock_service.expect(:subscription_details, sub_data)

    SubscriptionBillingService.stub(:new, ->(**_args) { mock_service }) do
      get "#{API_PREFIX}/instances/#{@instance.id}/billing/subscription",
        headers: headers
      assert_response :ok
      json = JSON.parse(response.body)
      assert_equal "active", json["status"]
    end
    mock_service.verify
  end

  test "subscription_details as member with a flat plan subscription returns 200" do
    headers = doorkeeper_headers_for(@member_user)
    flat_data = {
      type: "stripe", plan: "growth_250k", interval: "monthly", mau_cap: 250_000, maus: 1_000,
      details: { active: true, paused: false },
      stripe_subscription: { current_period_start: 1_700_000_000, current_period_end: 1_702_592_000 },
      amount_cents: 4900, next_payment_attempt: 1_702_592_000,
      period_start: 1_700_000_000, period_end: 1_702_592_000, cancels_at: nil,
      latest_invoice: { number: "GRV-0001", invoice_pdf: "https://pay.stripe.com/pdf", hosted_invoice_url: nil,
                        amount_paid: 4900, status: "paid", paid_at: 1_700_000_100 },
      billed_to: { name: "Acme Ltd", tax_id: nil, address_lines: ["1 Main St", "010101 Bucharest", "RO"] }
    }
    mock_service = Minitest::Mock.new
    mock_service.expect(:subscription_details, flat_data)

    SubscriptionBillingService.stub(:new, ->(**_args) { mock_service }) do
      get "#{API_PREFIX}/instances/#{@instance.id}/billing/subscription",
        headers: headers
      assert_response :ok
      json = JSON.parse(response.body)
      assert_equal "growth_250k", json["plan"]
      assert_equal "GRV-0001", json["latest_invoice"]["number"]
      assert_equal "Acme Ltd", json["billed_to"]["name"]
    end
    mock_service.verify
  end

  test "subscription_details accepts a flat plan with no invoice yet" do
    flat_data = {
      type: "stripe", plan: "growth_250k", interval: "monthly", mau_cap: 250_000, maus: 0,
      details: { active: false, paused: false },
      stripe_subscription: { current_period_start: nil, current_period_end: nil },
      amount_cents: nil, next_payment_attempt: nil, period_start: nil, period_end: nil, cancels_at: nil,
      latest_invoice: nil, billed_to: nil
    }
    mock_service = Minitest::Mock.new
    mock_service.expect(:subscription_details, flat_data)

    SubscriptionBillingService.stub(:new, ->(**_args) { mock_service }) do
      get "#{API_PREFIX}/instances/#{@instance.id}/billing/subscription", headers: doorkeeper_headers_for(@member_user)
      assert_response :ok
      assert_nil JSON.parse(response.body)["latest_invoice"]
    end
    mock_service.verify
  end

  test "subscription_details as member with a payment issue returns 200" do
    headers = doorkeeper_headers_for(@member_user)
    payment_issue_data = { type: "stripe", payment_issue: true, status: "past_due", plan: "growth_250k" }
    mock_service = Minitest::Mock.new
    mock_service.expect(:subscription_details, payment_issue_data)

    SubscriptionBillingService.stub(:new, ->(**_args) { mock_service }) do
      get "#{API_PREFIX}/instances/#{@instance.id}/billing/subscription",
        headers: headers
      assert_response :ok
      json = JSON.parse(response.body)
      assert json["payment_issue"]
      assert_equal "past_due", json["status"]
    end
    mock_service.verify
  end

  # --- cancel_subscription ---

  test "cancel_subscription as member returns 403" do
    headers = doorkeeper_headers_for(@member_user)
    mock_service = Minitest::Mock.new

    SubscriptionBillingService.stub(:new, ->(**_args) { mock_service }) do
      delete "#{API_PREFIX}/instances/#{@instance.id}/billing/subscription",
        headers: headers
      assert_response :forbidden
    end
  end

  # --- resume_subscription ---

  test "resume_subscription as member returns 403" do
    headers = doorkeeper_headers_for(@member_user)
    mock_service = Minitest::Mock.new

    SubscriptionBillingService.stub(:new, ->(**_args) { mock_service }) do
      post "#{API_PREFIX}/instances/#{@instance.id}/billing/subscription/resume",
        headers: headers
      assert_response :forbidden
    end
  end
end

class PaymentsBillingActionsTest < ActionDispatch::IntegrationTest
  include AuthTestHelper

  fixtures :instances, :users, :instance_roles, :projects

  setup do
    @instance = instances(:one)
    @admin_headers = doorkeeper_headers_for(users(:admin_user))
  end

  def stub_billing(mock_service, &blk)
    SubscriptionBillingService.stub(:new, ->(**_args) { mock_service }, &blk)
  end

  test "stripe_dashboard_url returns the portal URL" do
    mock = Minitest::Mock.new
    mock.expect(:portal_url, { url: "https://billing.stripe.com/p/session_123" })

    stub_billing(mock) do
      get "#{API_PREFIX}/instances/#{@instance.id}/billing/stripe_portal",
        headers: @admin_headers
    end

    assert_response :ok
    assert_equal "https://billing.stripe.com/p/session_123", JSON.parse(response.body)["url"]
    mock.verify
  end

  test "stripe_dashboard_url without auth returns 401" do
    get "#{API_PREFIX}/instances/#{@instance.id}/billing/stripe_portal",
      headers: api_headers
    assert_response :unauthorized
  end

  test "cancel_subscription cancels via the billing service" do
    mock = Minitest::Mock.new
    mock.expect(:cancel_subscription, { "status" => "canceled" })

    stub_billing(mock) do
      delete "#{API_PREFIX}/instances/#{@instance.id}/billing/subscription",
        headers: @admin_headers
    end

    assert_response :ok
    assert_equal true, JSON.parse(response.body)["result"]
    mock.verify
  end

  test "cancel_subscription with no active subscription returns 404" do
    mock = Minitest::Mock.new
    mock.expect(:cancel_subscription, nil)

    stub_billing(mock) do
      delete "#{API_PREFIX}/instances/#{@instance.id}/billing/subscription",
        headers: @admin_headers
    end

    assert_response :not_found
    assert_equal "No active subscriptions", JSON.parse(response.body)["error"]
  end

  test "cancel_subscription returns 502 when Stripe fails to cancel" do
    mock = Minitest::Mock.new
    mock.expect(:cancel_subscription, false)

    stub_billing(mock) do
      delete "#{API_PREFIX}/instances/#{@instance.id}/billing/subscription",
        headers: @admin_headers
    end

    assert_response :bad_gateway
    assert_equal "Could not cancel the subscription, please try again", JSON.parse(response.body)["error"]
  end

  # --- resume_subscription ---

  test "resume_subscription resumes via the billing service" do
    mock = Minitest::Mock.new
    mock.expect(:resume_subscription, { "status" => "active" })

    stub_billing(mock) do
      post "#{API_PREFIX}/instances/#{@instance.id}/billing/subscription/resume",
        headers: @admin_headers
    end

    assert_response :ok
    assert_equal true, JSON.parse(response.body)["result"]
    mock.verify
  end

  test "resume_subscription with nothing to resume returns 404" do
    mock = Minitest::Mock.new
    mock.expect(:resume_subscription, nil)

    stub_billing(mock) do
      post "#{API_PREFIX}/instances/#{@instance.id}/billing/subscription/resume",
        headers: @admin_headers
    end

    assert_response :not_found
    assert_equal "Nothing to resume", JSON.parse(response.body)["error"]
  end

  test "resume_subscription returns 502 when Stripe fails to resume" do
    mock = Minitest::Mock.new
    mock.expect(:resume_subscription, false)

    stub_billing(mock) do
      post "#{API_PREFIX}/instances/#{@instance.id}/billing/subscription/resume",
        headers: @admin_headers
    end

    assert_response :bad_gateway
    assert_equal "Could not resume the subscription, please try again", JSON.parse(response.body)["error"]
  end

  test "resume_subscription without auth returns 401" do
    post "#{API_PREFIX}/instances/#{@instance.id}/billing/subscription/resume",
      headers: api_headers
    assert_response :unauthorized
  end

  test "current_mau returns the billing service value" do
    mock = Minitest::Mock.new
    mock.expect(:current_mau, { current_quantity: 1234, total_available: "10000" })

    stub_billing(mock) do
      get "#{API_PREFIX}/instances/#{@instance.id}/billing/mau", headers: @admin_headers
    end

    assert_response :ok
    assert_equal 1234, JSON.parse(response.body)["current_quantity"]
  end

  test "self-hosted mode does NOT gate read-only analytics (current_mau stays reachable)" do
    ENV["GROVS_SELF_HOSTED"] = "true"
    mock = Minitest::Mock.new
    mock.expect(:current_mau, { current_quantity: 7, total_available: "999999999" })

    stub_billing(mock) do
      get "#{API_PREFIX}/instances/#{@instance.id}/billing/mau", headers: @admin_headers
    end

    assert_response :ok, "current_mau must remain reachable in self-hosted mode (not gated)"
    assert_equal 7, JSON.parse(response.body)["current_quantity"]
  ensure
    ENV.delete("GROVS_SELF_HOSTED")
  end

  test "current_usage returns usage payload when subscribed" do
    mock = Minitest::Mock.new
    mock.expect(:current_usage,
                { amount: 4900, maus: 10, next_payment_attempt: "2026-07-01", start_date: "2026-06-01" })

    stub_billing(mock) do
      get "#{API_PREFIX}/instances/#{@instance.id}/billing/usage", headers: @admin_headers
    end

    assert_response :ok
    json = JSON.parse(response.body)
    assert_equal 10, json["maus"]
    assert_equal 4900, json["amount"]
  end

  test "current_usage returns a flat plan usage payload when subscribed to a flat plan" do
    mock = Minitest::Mock.new
    flat_data = {
      type: "stripe", plan: "growth_250k", interval: "monthly", mau_cap: 250_000, maus: 1_000,
      details: { active: true, paused: false },
      stripe_subscription: { current_period_start: 1_700_000_000, current_period_end: 1_702_592_000 },
      amount_cents: 4900, next_payment_attempt: 1_702_592_000,
      period_start: 1_700_000_000, period_end: 1_702_592_000, cancels_at: nil, latest_invoice: nil, billed_to: nil
    }
    mock.expect(:current_usage, flat_data)

    stub_billing(mock) do
      get "#{API_PREFIX}/instances/#{@instance.id}/billing/usage", headers: @admin_headers
    end

    assert_response :ok
    json = JSON.parse(response.body)
    assert_equal "growth_250k", json["plan"]
  end

  test "current_usage with no subscription returns 404" do
    mock = Minitest::Mock.new
    mock.expect(:current_usage, nil)

    stub_billing(mock) do
      get "#{API_PREFIX}/instances/#{@instance.id}/billing/usage", headers: @admin_headers
    end

    assert_response :not_found
  end
end
