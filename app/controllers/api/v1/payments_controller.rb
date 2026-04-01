class Api::V1::PaymentsController < Api::V1::ProjectsBaseController
  include DashboardAuthorization
  before_action :doorkeeper_authorize!
  before_action :load_instance
  before_action :check_access, only: [:create_subscription_session, :stripe_dashboard_url, :cancel_subscription]

  def create_subscription_session
    result = billing_service.create_checkout_session(user: current_user)
    render json: { url: result[:url] }, status: :ok
  rescue ArgumentError
    render json: { error: "This project is already subscribed" }, status: :unprocessable_entity
  end

  def stripe_dashboard_url
    result = billing_service.portal_url
    render json: { url: result[:url] }, status: :ok
  end

  def cancel_subscription
    result = billing_service.cancel_subscription
    if result.nil?
      render json: { error: "No active subscriptions" }, status: :not_found
    else
      render json: { result: result }, status: :ok
    end
  end

  def subscription_details
    result = billing_service.subscription_details
    if result
      render json: result, status: :ok
    else
      render json: { error: "No active subscriptions" }, status: :not_found
    end
  end

  def current_mau
    render json: billing_service.current_mau
  end

  def current_usage
    result = billing_service.current_usage
    if result
      render json: result, status: :ok
    else
      render json: { error: "No active subscription" }, status: :not_found
    end
  end

  private

  def billing_service
    SubscriptionBillingService.new(instance: @instance)
  end

  def check_access
    unless current_user.admin?(current_instance)
      render json: { error: "Forbidden" }, status: :forbidden
      return false
    end

    true
  end
end
