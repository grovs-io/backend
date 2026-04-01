class Application < ApplicationRecord
  include ModelCachingExtension

  belongs_to :instance

  has_one :ios_configuration
  has_one :android_configuration
  has_one :desktop_configuration
  has_one :web_configuration

  has_many :redirects, dependent: :destroy

  validates :platform, inclusion: { in: Grovs::Platforms::ALL }

  # Methods
  def configuration
    Rails.cache.fetch([self, 'configuration'], expires_in: 1.hour) do
      case platform.downcase
          when Grovs::Platforms::IOS then ios_configuration
          when Grovs::Platforms::ANDROID then android_configuration
          when Grovs::Platforms::WEB then web_configuration
          when Grovs::Platforms::DESKTOP, Grovs::Platforms::WINDOWS, Grovs::Platforms::MAC then desktop_configuration
      end
    end
  rescue TypeError, ArgumentError => e
    Rails.logger.error("Application#configuration cache error for #{id}: #{e.message}")
    clear_configuration_cache
    case platform.downcase
        when Grovs::Platforms::IOS then ios_configuration
        when Grovs::Platforms::ANDROID then android_configuration
        when Grovs::Platforms::WEB then web_configuration
        when Grovs::Platforms::DESKTOP, Grovs::Platforms::WINDOWS, Grovs::Platforms::MAC then desktop_configuration
    end
  end

  def clear_configuration_cache
    Rails.cache.delete([self, 'configuration'])
  end

  def cache_keys_to_clear
    keys = super
    if instance_id && platform
      keys << multi_condition_cache_key({instance_id: instance_id, platform: platform})
    end
    keys
  end
end
