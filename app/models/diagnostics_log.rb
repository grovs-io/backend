class DiagnosticsLog < ApplicationRecord
  validates :test_key, presence: true
  validates :operation, presence: true
end
