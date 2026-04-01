class Event < ApplicationRecord
  # Mandatory
  belongs_to :project
  belongs_to :device

  # Optional
  belongs_to :link, optional: true

  scope :for_project, ->(project_id) { where(project_id: project_id) }

  validates :event, inclusion: { in: Grovs::Events::ALL }

  def self.clamp_engagement_time(value)
    return nil if value.nil?
    value.to_i
  end

  APP_SPECIFIC_EVENTS = [Grovs::Events::APP_OPEN, Grovs::Events::INSTALL, Grovs::Events::REINSTALL, Grovs::Events::REACTIVATION].freeze

  def platform_for_metrics
    case self.platform
    when Grovs::Platforms::ANDROID, Grovs::Platforms::IOS
      self.platform
    else
      Grovs::Platforms::WEB
    end
  end

  def valid_for_platform_metrics?
    e = event.to_s.downcase
    p = platform.to_s.downcase

    return true unless APP_SPECIFIC_EVENTS.include?(e)
    [Grovs::Platforms::IOS, Grovs::Platforms::ANDROID].include?(p)
  end
end
