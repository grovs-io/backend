class Campaign < ApplicationRecord
  belongs_to :project
  has_many :links, dependent: :nullify

  validates :name, presence: true

end
