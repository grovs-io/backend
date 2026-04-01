class StripePaymentIntent < ApplicationRecord
  belongs_to :user
  belongs_to :instance
  has_one :stripe_subscription
end
