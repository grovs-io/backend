require 'hashids'
require "browser"

class Device < ApplicationRecord
  include Hashid::Rails
  include ModelCachingExtension
  include UserAgentHelper

  validates :user_agent, presence: true
  validates :ip, presence: true
  validates :remote_ip, presence: true

  scope :by_platform, ->(platform) { where(platform: platform) }

  has_many :actions
  has_many :events
    
  has_many :visitors, dependent: :destroy

  has_many :installed_apps, dependent: :destroy
  has_many :installed_projects, through: :installed_apps, source: :project

  def visitor_for_project_id(project_id)
    Visitor.redis_find_by_multiple_conditions({ project_id: project_id, device_id: id }, includes: [:device])
  end

  def user_agent_platform
    browser = Browser.new(user_agent)
    if browser.platform.ios?
      return Grovs::Platforms::IOS
    end

    if browser.platform.android?
      return Grovs::Platforms::ANDROID
    end

    if browser.platform.windows?
      return Grovs::Platforms::WINDOWS
    end

    if browser.platform.mac?
      return Grovs::Platforms::MAC
    end

    Grovs::Platforms::WEB
  end

  def platform_for_metrics
    case self.platform
    when Grovs::Platforms::ANDROID, Grovs::Platforms::IOS
      self.platform
    else
      Grovs::Platforms::WEB
    end
  end

  def bot?
    social_media_preview?(user_agent)
  end

  def self.fetch_by_hash_id(linkedsquared_id)
    decoded_id = Device.decode_id(linkedsquared_id)
    Device.redis_find_by(:id, decoded_id)
  end

  def cache_keys_to_clear
    keys = super
    prefix = self.class.cache_prefix
    keys << "#{prefix}:find_by:vendor:#{vendor}:no_includes" if vendor.present?
    # Clear old vendor key if vendor changed
    if previous_changes.key?('vendor') && previous_changes['vendor'][0].present?
      keys << "#{prefix}:find_by:vendor:#{previous_changes['vendor'][0]}:no_includes"
    end
    keys
  end
end
