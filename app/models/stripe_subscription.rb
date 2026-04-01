class StripeSubscription < ApplicationRecord
  belongs_to :instance
  belongs_to :stripe_payment_intent

  validates :subscription_id, presence: true
  validates :status, presence: true
  validates :customer_id, presence: true
end
