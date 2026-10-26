class SegmentMembership < ApplicationRecord
  self.primary_key = %i[visitor_id segment_key]
end
