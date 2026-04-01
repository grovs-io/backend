require 'httparty'
require 'json'
require 'jwt'

class AppleIapService
  include AppleIapService::PurchaseEventHandling
  include AppleIapService::SubscriptionHandler
  include AppleIapService::RefundHandler

  # Notification types from Apple's documentation
  NOTIFICATION_TYPES = {
    'CONSUMPTION_REQUEST' => 'consumption_request',
    'DID_CHANGE_RENEWAL_PREF' => 'did_change_renewal_pref',
    'DID_CHANGE_RENEWAL_STATUS' => 'did_change_renewal_status',
    'DID_FAIL_TO_RENEW' => 'did_fail_to_renew',
    'DID_RENEW' => 'did_renew',
    'EXPIRED' => 'expired',
    'GRACE_PERIOD_EXPIRED' => 'grace_period_expired',
    'OFFER_REDEEMED' => 'offer_redeemed',
    'PRICE_INCREASE' => 'price_increase',
    'REFUND' => 'refund',
    'REFUND_DECLINED' => 'refund_declined',
    'REFUND_REVERSED' => 'refund_reversed',
    'RENEWAL_EXTENDED' => 'renewal_extended',
    'REVOKE' => 'revoke',
    'SUBSCRIBED' => 'subscribed',
    'TEST' => 'test',
    'ONE_TIME_CHARGE' => 'one_time_charge',
    'EXTERNAL_PURCHASE_TOKEN' => 'external_purchase_token',
    'METADATA_UPDATE' => 'metadata_update',
    'MIGRATION' => 'migration',
    'PRICE_CHANGE' => 'price_change',
    'RENEWAL_EXTENSION' => 'renewal_extension',
    'RESCIND_CONSENT' => 'rescind_consent'
  }.freeze

  # Subtypes for various notification types
  SUBTYPES = {
    'INITIAL_BUY' => 'initial_buy',
    'RESUBSCRIBE' => 'resubscribe',
    'DOWNGRADE' => 'downgrade',
    'UPGRADE' => 'upgrade',
    'AUTO_RENEW_ENABLED' => 'auto_renew_enabled',
    'AUTO_RENEW_DISABLED' => 'auto_renew_disabled',
    'VOLUNTARY' => 'voluntary',
    'BILLING_RETRY' => 'billing_retry',
    'PRICE_INCREASE' => 'price_increase',
    'GRACE_PERIOD' => 'grace_period',
    'BILLING_RECOVERY' => 'billing_recovery',
    'PENDING' => 'pending',
    'ACCEPTED' => 'accepted'
  }.freeze

  def initialize
    @logger = Rails.logger
    @event_creator = PurchaseEventCreator.new
  end

  def handle_notification(notification, project)
    return false unless notification && notification["signedPayload"]

    data = notification["signedPayload"]

    begin
      verified_receipt = AppStoreServerApi::Utils::Decoder.decode_jws!(data)

      # Log the notification for debugging
      @logger.info "Processing Apple notification: #{verified_receipt['notificationType']}"

      handle_apple_notification(verified_receipt, data, project)

    rescue JWT::DecodeError, OpenSSL::OpenSSLError, JSON::ParserError => e
      @logger.error "Apple notification decode error: #{e.class} - #{e.message}"
      false
    end
  end

  private

  def handle_apple_notification(verified_receipt, data, project)
    type = verified_receipt["notificationType"]
    subtype = verified_receipt["subtype"]
    identifier = verified_receipt.dig("data", "bundleId")

    unless identifier
      @logger.error "No identifier (bundleId) found in notification"
      return false
    end

    # Log unknown notification types but still acknowledge receipt
    unless NOTIFICATION_TYPES.key?(type)
      @logger.warn "Unknown notification type: #{type}"
      return true
    end

    # Create webhook message record for audit trail
    webhook = IapWebhookMessage.create!(
      payload: data,
      notification_type: type,
      source: Grovs::Webhooks::APPLE,
      project: project,
      instance: project.instance
    )

    handle_transaction(type, subtype, verified_receipt, project)

  rescue ActiveRecord::RecordInvalid, NoMethodError, KeyError, ArgumentError => e
    @logger.error "Apple notification processing error: #{e.class} - #{e.message}"
    false
  end

  def handle_transaction(type, subtype, verified_receipt, project)
    subscription_info = extract_subscription_details(verified_receipt)
    unless subscription_info
      @logger.error "Failed to extract subscription details"
      return false
    end

    subscription_info[:purchase_type] = type == 'ONE_TIME_CHARGE' ? Grovs::Purchases::TYPE_ONE_TIME : Grovs::Purchases::TYPE_SUBSCRIPTION

    @logger.info "Processing transaction - Type: #{type}, Subtype: #{subtype}, Product: #{subscription_info[:product_id]}"

    case type
    when 'SUBSCRIBED'
      handle_subscribed_event(subtype, subscription_info, project)
    when 'DID_CHANGE_RENEWAL_PREF'
      handle_renewal_preference_change(subtype, subscription_info, project)
    when 'DID_CHANGE_RENEWAL_STATUS'
      handle_renewal_status_change(subtype, subscription_info, project)
    when 'DID_RENEW'
      handle_renewal_event(subtype, subscription_info, project)
    when 'DID_FAIL_TO_RENEW'
      handle_renewal_failure(subtype, subscription_info, project)
    when 'EXPIRED'
      handle_expiration_event(subtype, subscription_info, project)
    when 'GRACE_PERIOD_EXPIRED'
      handle_grace_period_expired(subscription_info, project)
    when 'REFUND'
      handle_refund_event(subscription_info, project)
    when 'REFUND_DECLINED'
      handle_refund_declined(subscription_info, project)
    when 'REFUND_REVERSED'
      handle_refund_reversed(subscription_info, project)
    when 'REVOKE'
      handle_revoke_event(subscription_info, project)
    when 'RENEWAL_EXTENDED'
      handle_renewal_extended(subscription_info, project)
    when 'OFFER_REDEEMED'
      handle_offer_redeemed(subtype, subscription_info, project)
    when 'PRICE_INCREASE'
      handle_price_increase(subtype, subscription_info, project)
    when 'CONSUMPTION_REQUEST'
      handle_consumption_request(subscription_info, project)
    when 'ONE_TIME_CHARGE'
      handle_one_time_charge(subscription_info, project)
    when 'TEST'
      handle_test_notification(subscription_info, project)
    when 'EXTERNAL_PURCHASE_TOKEN', 'METADATA_UPDATE', 'MIGRATION',
         'PRICE_CHANGE', 'RENEWAL_EXTENSION', 'RESCIND_CONSENT'
      @logger.info "Informational notification #{type} received"
    else
      @logger.warn "Unhandled notification type: #{type}"
    end

    true
  end

  # Handle RENEWAL_EXTENDED notification - not a new purchase, just period extension
  def handle_renewal_extended(subscription_info, project)
    @logger.info "Renewal extended for transaction: #{subscription_info[:transaction_id]}"
    true
  end

  # Handle PRICE_INCREASE notification — informational only, no purchase event
  # New price takes effect at next DID_RENEW
  def handle_price_increase(subtype, subscription_info, project)
    @logger.info "Price increase #{subtype || 'notification'} for transaction: #{subscription_info[:transaction_id]}"
  end

  # Handle CONSUMPTION_REQUEST notification - Apple is requesting consumption data, not a purchase
  def handle_consumption_request(subscription_info, project)
    @logger.info "Consumption request received for transaction: #{subscription_info[:transaction_id]}"
    true
  end

  # Handle TEST notification
  def handle_test_notification(subscription_info, project)
    @logger.info "Test notification received - ignoring"
    true
  end

end
