module AppleIapService::RefundHandler
  extend ActiveSupport::Concern

  private

  # Handle REFUND notification - maps to REFUND
  def handle_refund_event(subscription_info, project)
    handle_subscription_event_type(Grovs::Purchases::EVENT_REFUND, subscription_info, project)
  end

  # Handle REFUND_DECLINED notification - no event needed
  def handle_refund_declined(subscription_info, project)
    @logger.info "Refund declined for transaction: #{subscription_info[:transaction_id]}"
    true
  end

  # Handle REFUND_REVERSED notification - maps to REFUND_REVERSED
  def handle_refund_reversed(subscription_info, project)
    handle_subscription_event_type(Grovs::Purchases::EVENT_REFUND_REVERSED, subscription_info, project)
  end
end
