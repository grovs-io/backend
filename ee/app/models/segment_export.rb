class SegmentExport < ApplicationRecord
  include Hashid::Rails

  STATUSES = %w[pending ready failed expired].freeze
  DOWNLOAD_TTL = 5.minutes

  belongs_to :project
  belongs_to :segment
  belongs_to :user, optional: true
  has_one_attached :file

  validates :status, inclusion: { in: STATUSES }

  def download_url
    return nil unless status == "ready" && file.attached?

    file.url(expires_in: DOWNLOAD_TTL, disposition: "attachment")
  end
end
