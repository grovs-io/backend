class QuickLink < ApplicationRecord
  belongs_to :domain

  has_one_attached :image

  validate :path_must_be_unique, on: :create
  validate :ios_phone_must_be_valid_url
  validate :android_phone_must_be_valid_url

  validates :ios_tablet, :android_tablet, :desktop_mac, :desktop_windows, :desktop_linux, url: true, allow_blank: true
  validate :optional_urls_must_be_valid

  def image_resource
    if image_url
      return image_url
    end
      
    AssetService.permanent_url(image)
  end

  def valid_path?
    link = Link.find_by(domain: domain, path: path)
    link.nil?
  end

  # Validations
  def path_must_be_unique
    unless valid_path?
      errors.add(:path, "There's an existing link for this domain and path")
    end
  end

  def ios_phone_must_be_valid_url
    return if ios_phone.blank? # Skip if blank
    errors.add(:ios_phone, "is not a valid URL") unless valid_url?(ios_phone)
  end

  def android_phone_must_be_valid_url
    return if android_phone.blank? # Skip if blank
    errors.add(:android_phone, "is not a valid URL") unless valid_url?(android_phone)
  end

  def full_path(domain)
    subdomain = domain.subdomain
    domain = domain.domain
      
    "#{subdomain}.#{domain}/#{path}"
  end

  def access_path
    "https://#{full_path(domain)}"
  end

  def valid_url?(url)
    # Skip processing if url is nil
    return false if url.nil?
  
    url = url.strip
  
    # Try parsing the URL as is
    begin
      uri = URI.parse(url)

      # If the URI scheme is nil (no scheme provided), attempt to parse with http:// prefix
      if uri.scheme.nil?
        # Check if the URL looks like a domain name (has a dot and no spaces)
        if url.include?('.') && !url.include?(' ')
          uri = URI.parse("http://#{url}")
        else
          return false
        end
      end

      # Check if the host (domain) is present and valid
      uri.host.present? && uri.host.include?('.')
    rescue URI::InvalidURIError, TypeError
      # If parsing fails, return false
      false
    end
  end

  def optional_urls_must_be_valid
    optional_fields = [
      :ios_tablet,
      :android_tablet,
      :desktop_mac,
      :desktop_windows,
      :desktop_linux
    ]
  
    optional_fields.each do |field|
      if self[field].present? && !valid_url?(self[field])
        errors.add(field, 'must be a valid URL')
      end
    end
  end
end
