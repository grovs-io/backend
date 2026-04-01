class IapWebhookMessage < ApplicationRecord
  belongs_to :project, optional: true
  belongs_to :instance, optional: true

  # Validations
  validates :payload, presence: true
  validates :source, presence: true, inclusion: { in: Grovs::Webhooks::SOURCES }
end
