class StoreImage < ApplicationRecord
  has_one_attached :image
  validates :identifier, presence: true

  def image_access_url
    AssetService.permanent_url(image)
  end
end
