class Campaign < ApplicationRecord
  belongs_to :project
  has_many :links, dependent: :destroy

  validates :name, presence: true

end
