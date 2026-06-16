class Domain < ApplicationRecord
  include ModelCachingExtension

  validates :domain, presence: true

  has_one_attached :generic_image

  belongs_to :project
    
  has_many :links, dependent: :destroy
  has_many :quick_links, dependent: :destroy
  has_many :custom_hostnames, dependent: :destroy

  def image_url
    if generic_image_url
      return generic_image_url
    end
      
    AssetService.permanent_url(generic_image)
  end

  def cache_keys_to_clear
    keys = super
    keys << multi_condition_cache_key({domain: self.domain, subdomain: subdomain}) if self.domain.present?
    keys
  end

  def full_domain
    if subdomain.blank?
      return domain 
    end

    "#{subdomain}.#{domain}"
  end

  # Branded outbound host: the active custom domain when present, else the sqd.link
  # host. Reads the denormalized column off this already-loaded record so the hot
  # path stays query-free. Maintained transactionally by the custom-domain jobs.
  def display_host
    return full_domain unless Grovs.custom_domains_enabled?

    active_custom_host.presence || full_domain
  end
end
