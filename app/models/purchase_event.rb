class PurchaseEvent < ApplicationRecord
  belongs_to :project, optional: true
  belongs_to :device, optional: true
  belongs_to :link, optional: true

  validates :event_type, presence: true, inclusion: { in: Grovs::Purchases::ALL_EVENTS }
  validates :purchase_type, inclusion: { in: Grovs::Purchases::TYPES }, allow_nil: true
  validates :price_cents, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validates :store_source, inclusion: { in: [Grovs::Webhooks::APPLE, Grovs::Webhooks::GOOGLE] }, allow_nil: true

  STORE_SOURCE_PLATFORM = { Grovs::Webhooks::APPLE => Grovs::Platforms::IOS, Grovs::Webhooks::GOOGLE => Grovs::Platforms::ANDROID }.freeze

  def store_platform
    STORE_SOURCE_PLATFORM[store_source]
  end

  # Callback to calculate the price in USD before saving
  before_save :convert_price_to_usd, if: lambda {
    next false unless defined?(CurrencyConversionService)
    next false unless price_cents.present? && currency.present?
    # No USD price yet — must convert
    next true if usd_price_cents.nil?
    # Price or currency updated on a persisted record — re-convert
    # (new_record? guard prevents re-converting when usd_price_cents is set on create)
    !new_record? && (will_save_change_to_price_cents? || will_save_change_to_currency?)
  }
  before_save :assign_unique_transaction_id, if: -> { transaction_id.nil? }

  def buy?
    [Grovs::Purchases::EVENT_BUY, Grovs::Purchases::EVENT_REFUND_REVERSED].include?(event_type)
  end

  # Cancel always counts as cancellation.
  # Refund counts as cancellation only for one_time/rental purchases (purchase voided),
  # NOT for subscriptions (money returned but subscription is a separate concept).
  def cancellation?
    event_type == Grovs::Purchases::EVENT_CANCEL ||
      (event_type == Grovs::Purchases::EVENT_REFUND && purchase_type != Grovs::Purchases::TYPE_SUBSCRIPTION)
  end

  # Signed revenue delta in USD cents for this event.
  # Pass +cents+ to compute for an arbitrary amount (used for corrections);
  # defaults to the persisted usd_price_cents.
  def revenue_delta(cents = usd_price_cents.to_i)
    return nil if cents == 0

    case event_type
    when Grovs::Purchases::EVENT_BUY, Grovs::Purchases::EVENT_REFUND_REVERSED then cents * quantity
    when Grovs::Purchases::EVENT_REFUND then -(cents * quantity)
    when Grovs::Purchases::EVENT_CANCEL
      purchase_type != Grovs::Purchases::TYPE_SUBSCRIPTION ? -(cents * quantity) : nil
    end
  end

  # Method to convert the price to USD using the CurrencyConversionHelper
  def convert_price_to_usd
    converted = CurrencyConversionService.to_usd_cents(price_cents, currency)
    if converted.nil?
      Rails.logger.warn("CurrencyConversion failed for PurchaseEvent price_cents=#{price_cents} currency=#{currency}")
    else
      self.usd_price_cents = converted
    end
  end

  # Ensures a unique transaction ID is assigned if missing
  def assign_unique_transaction_id
    self.transaction_id = SecureRandom.uuid
  end

end
