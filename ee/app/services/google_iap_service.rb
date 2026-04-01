class GoogleIapService
  include GoogleIapService::PurchaseEventHandling
  include GoogleIapService::SubscriptionHandler
  include GoogleIapService::OneTimeProductHandler
  include GoogleIapService::RefundHandler
  include GoogleIapService::BundleHandler

  def initialize
    @logger = Rails.logger
    @event_creator = PurchaseEventCreator.new
  end

  def handle_notification(notification, instance, iap_webhook_message)
    package_name = notification["packageName"]
    unless package_name
      @logger.error "Google notification missing packageName"
      return false
    end

    @service = IapUtils.build_google_service(instance)
    raise "Google Play API key file is missing" unless @service

    if notification.key?("subscriptionNotification")
      handle_subscription_notification(notification, instance, iap_webhook_message, package_name)
    elsif notification.key?("oneTimeProductNotification")
      handle_one_time_notification(notification, instance, iap_webhook_message, package_name)
    elsif notification.key?("voidedPurchaseNotification")
      handle_voided_notification(notification, instance, iap_webhook_message, package_name)
    else
      iap_webhook_message.update(notification_type: "UNKNOWN_TYPE")
      @logger.warn("Unrecognized notification type: #{notification}")
      :skipped
    end
  rescue Google::Apis::AuthorizationError, Google::Apis::ClientError,
         ActiveRecord::RecordInvalid, JSON::ParserError, RuntimeError => e
    @logger.error "Google handle_notification non-retryable error: #{e.class} - #{e.message}"
    false
  end
end
