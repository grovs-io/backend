class SubscriptionState < ApplicationRecord
  belongs_to :project
  belongs_to :device, optional: true
  belongs_to :link, optional: true

  validates :original_transaction_id, presence: true
end
