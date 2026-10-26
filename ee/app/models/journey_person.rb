class JourneyPerson < ApplicationRecord
  STATES = %w[active claimed left].freeze

  belongs_to :journey

  INSIDE = %w[active claimed].freeze

  scope :inside, -> { where(state: INSIDE) }
end
