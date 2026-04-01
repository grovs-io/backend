class FailedPurchaseJob < ApplicationRecord
  STATUSES = %w[pending retried discarded].freeze

  validates :job_class, presence: true
  validates :arguments, presence: true
  validates :status, presence: true, inclusion: { in: STATUSES }

  scope :pending, -> { where(status: 'pending') }

  def retry!
    raise "Cannot retry a #{status} job" unless status == 'pending'

    job_class.constantize.perform_async(*arguments)
    update!(status: 'retried', retried_at: Time.current)
  end
end
