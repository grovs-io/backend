class VisitorLastVisit < ApplicationRecord
  belongs_to :project
  belongs_to :visitor
  belongs_to :link, optional: true


end
