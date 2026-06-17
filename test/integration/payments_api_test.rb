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

  test "create_subscription_session as admin returns checkout URL" do
    headers = doorkeeper_headers_for(@admin_user)
    mock_service = Minitest::Mock.new
    mock_service.expect(:create_checkout_session, { url: "https://checkout.stripe.com/test_session" }, user: @admin_user)

    SubscriptionBillingService.stub(:new, ->(**_args) { mock_service }) do
      post "#{API_PREFIX}/instances/#{@instance.id}/billing/subscriptions",
        headers: headers
      assert_response :ok
      json = JSON.parse(response.body)
      assert_equal "https://checkout.stripe.com/test_session", json["url"]
    end
    mock_service.verify
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
    assert_equal "canceled", JSON.parse(response.body).dig("result", "status")
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

  test "current_usage with no subscription returns 404" do
    mock = Minitest::Mock.new
    mock.expect(:current_usage, nil)

    stub_billing(mock) do
      get "#{API_PREFIX}/instances/#{@instance.id}/billing/usage", headers: @admin_headers
    end

    assert_response :not_found
  end
end
