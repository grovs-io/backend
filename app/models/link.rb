class Link < ApplicationRecord
  include ModelCachingExtension
    
  belongs_to :domain
  belongs_to :redirect_config

  has_one_attached :image

  validate :path_must_be_unique, on: :create

  has_many :events
  belongs_to :visitor, optional: true

  scope :active, -> { where(active: true) }

  has_many :actions

  validates :ads_platform, inclusion: { in: Grovs::Ads::PLATFORMS }, allow_nil: true
  belongs_to :campaign, optional: true

  has_many :custom_redirects, dependent: :destroy
  has_many :link_daily_statistics, dependent: :destroy

  def image_resource
    if image_url
      return image_url
    end
      
    AssetService.permanent_url(image)
  end

  def valid_path?
    link = Link.find_by(domain: domain, path: path, active: true)
    [nil, self].include?(link)
  end

  def should_open_app_on_platform?(platform)
    should_open_app = false

    if platform == Grovs::Platforms::IOS
      should_open_app = redirect_config.ios_phone_redirect&.enabled || false
      if ios_custom_redirect
        should_open_app = ios_custom_redirect.open_app_if_installed
      end

    elsif platform == Grovs::Platforms::ANDROID
      should_open_app = redirect_config.android_phone_redirect&.enabled || false
      if android_custom_redirect
        should_open_app = android_custom_redirect.open_app_if_installed
      end

    elsif [Grovs::Platforms::DESKTOP, Grovs::Platforms::WEB].include?(platform)
      should_open_app = false
    end

    should_open_app
  end

  # Validations
  def path_must_be_unique
    unless valid_path?
      errors.add(:path, "There's an existing link for this domain and path")
    end
  end

  def full_path(domain)
    host = domain.full_domain
      
    "#{host}/#{path}"
  end

  def access_path
    "https://#{full_path(domain)}"
  end

  def action_for(device)
    actions.where(device_id: device.id).where("created_at >= ?", Grovs::Links::VALIDITY_MINUTES.minutes.ago).order(created_at: :desc).first
  end

  def hash_data
    data.reduce({}) do |acc, hash|
      acc.merge(hash)
    end

    
  end

  def ios_custom_redirect
    custom_redirect_for(Grovs::Platforms::IOS)
  end

  def android_custom_redirect
    custom_redirect_for(Grovs::Platforms::ANDROID)
  end

  def desktop_custom_redirect
    custom_redirect_for(Grovs::Platforms::DESKTOP)
  end

  def custom_redirect_for(platform)
    if custom_redirects.loaded?
      custom_redirects.detect { |r| r.platform == platform }
    else
      custom_redirects.find_by(platform: platform)
    end
  end

  def tracking_dictionary
    {
      source: tracking_source,
      campaign: tracking_campaign,
      medium: tracking_medium
      }
  end

  def cache_keys_to_clear
    keys = super
    if domain_id && path
      keys << multi_condition_cache_key({path: path, domain_id: domain_id})
      keys << multi_condition_cache_key({domain: domain_id, path: path})
    end
    # Clear old keys if path or domain_id changed
    if previous_changes.key?('path') || previous_changes.key?('domain_id')
      old_path = previous_changes.dig('path', 0) || path
      old_domain_id = previous_changes.dig('domain_id', 0) || domain_id
      if old_domain_id && old_path
        keys << multi_condition_cache_key({path: old_path, domain_id: old_domain_id})
        keys << multi_condition_cache_key({domain: old_domain_id, path: old_path})
      end
    end
    keys
  end
end
