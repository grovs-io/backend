class EnterpriseSubscription < ApplicationRecord
  # Optional association, the subscription doesn't depend on the instance
  belongs_to :instance, optional: true

  # You can add validations if necessary
  validates :start_date, :end_date, :total_maus, presence: true

  
end
