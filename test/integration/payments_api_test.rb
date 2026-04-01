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
