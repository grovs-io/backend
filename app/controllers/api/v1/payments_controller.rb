class Api::V1::PaymentsController < Api::V1::ProjectsBaseController
  include DashboardAuthorization

  # Stripe-calling actions: admin-only, and disabled when self-hosted. The read
  # endpoints (current_mau/subscription_details/current_usage) are intentionally
  # left open — they serve analytics or 404 without any Stripe call.
  STRIPE_ACTIONS = %i[create_subscription_session stripe_dashboard_url cancel_subscription].freeze

  before_action :doorkeeper_authorize!
  before_action :load_instance
  before_action :check_access, only: STRIPE_ACTIONS
  before_action :reject_if_self_hosted, only: STRIPE_ACTIONS

  # CH-primary MAU read failed: surface an explicit 503, never a zero MAU.
  rescue_from ProjectService::MauReadUnavailable do |e|
    Rails.logger.error("clickhouse.mau.read_failed instance=#{@instance&.id} — #{e.message}")
    render json: { error: "Usage data temporarily unavailable" }, status: :service_unavailable
  end

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

  # 403 disabled response for STRIPE_ACTIONS when self-hosted (no Stripe keys).
  # { error } shape matches their existing contract. No-op on SaaS.
  def reject_if_self_hosted
    return unless Grovs.self_hosted?

    render json: { error: "Billing is disabled in self-hosted mode" }, status: :forbidden
  end

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
