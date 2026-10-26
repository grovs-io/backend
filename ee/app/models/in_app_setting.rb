class InAppSetting < ApplicationRecord
  DEFAULT_CAP = 10

  belongs_to :project

  validates :enabled, inclusion: { in: [true, false], message: "must be true or false" }
  validates :session_cap, :day_cap, numericality: { only_integer: true, greater_than: 0, less_than_or_equal_to: 1000 }
  validates :control_group, numericality: { only_integer: true, in: 0..20, message: "must be a whole number from 0 to 20" }
  validates :push_daily_cap, numericality: { only_integer: true, in: 1..50, message: "must be a whole number from 1 to 50, or null" }, allow_nil: true

  after_commit { InAppStamps.touch_campaigns(project_id) }

  def self.for(project) = find_by(project_id: project.id) || new(project: project)
end
