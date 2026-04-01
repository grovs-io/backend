class CustomRedirect < ApplicationRecord
  belongs_to :link

  validates :platform, presence: true, inclusion: { in: Grovs::Platforms::ALL }
  validates :url, presence: true
  validates :link_id, uniqueness: { scope: :platform }

end
