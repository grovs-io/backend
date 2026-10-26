class Dashboard < ApplicationRecord
  MAX_PER_PROJECT = 10

  belongs_to :project
  belongs_to :created_by, class_name: 'User', optional: true
  has_many :widgets, -> { order(:position, :id) }, class_name: 'DashboardWidget', dependent: :destroy

  validates :name, presence: true, length: { maximum: 100 }
  validate :within_project_cap, on: :create

  scope :ordered, -> { order(:position, :id) }

  private

  def within_project_cap
    return if project.nil? || project.dashboards.count < MAX_PER_PROJECT

    errors.add(:base, "a project can have at most #{MAX_PER_PROJECT} dashboards")
  end
end
