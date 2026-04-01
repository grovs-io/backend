class InAppProduct < ApplicationRecord
  belongs_to :project
  has_many :in_app_product_daily_statistics, dependent: :destroy

  validates :product_id, presence: true
  validates :platform, presence: true, inclusion: { in: Grovs::Platforms::ALL }
end
