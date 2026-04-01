class ProjectDailyActiveUser < ApplicationRecord
  belongs_to :project

  validates :project_id, :event_date, presence: true
end
