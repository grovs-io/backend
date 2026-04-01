class PurchaseValidationService
  class << self
    def validate(purchase_event, platform)
      return false unless purchase_event
      return true if purchase_event.webhook_validated?

      instance = purchase_event.project&.instance
      return false unless instance

      case platform
      when Grovs::Platforms::IOS     then ApplePurchaseValidator.validate(purchase_event, instance)
      when Grovs::Platforms::ANDROID then GooglePurchaseValidator.validate(purchase_event, instance)
      else
        Rails.logger.warn "PurchaseValidationService: unknown platform '#{platform}' for event #{purchase_event.id}"
        false
      end
    rescue Google::Apis::ClientError, Google::Apis::AuthorizationError,
           JWT::DecodeError, OpenSSL::OpenSSLError, JSON::ParserError,
           ArgumentError, ActiveRecord::RecordInvalid => e
      Rails.logger.error "PurchaseValidationService non-retryable error for event #{purchase_event&.id}: #{e.class} - #{e.message}"
      false
    end
  end
end
