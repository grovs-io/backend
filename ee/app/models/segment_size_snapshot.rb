class SegmentSizeSnapshot < ApplicationRecord
  belongs_to :segment

  scope :fresh, -> { where(date: 7.days.ago.to_date..) }
end
