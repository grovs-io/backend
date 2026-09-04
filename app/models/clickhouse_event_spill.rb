class ClickhouseEventSpill < ApplicationRecord
  MAX_DRAIN_ATTEMPTS = 10

  # Arel literal (not a bind) so the partial index matches
  scope :drainable, -> { where(arel_table[:attempts].lt(MAX_DRAIN_ATTEMPTS)).order(:spilled_at, :id) }
end
