class SmartBanner < ApplicationRecord
  LINK_PLATFORM = "smart_banner".freeze
  LINK_TAG = "smart_banner".freeze
  # links.tags is text[] and nullable: NULL must be let through explicitly, not via COALESCE.
  HIDE_LINKS_SQL = "(links.tags IS NULL OR NOT links.tags @> ARRAY['#{LINK_TAG}']::text[])".freeze
  PLATFORMS = %w[ios android].freeze
  POSITIONS = %w[top bottom].freeze
  STATUSES = %w[draft live paused archived].freeze
  CREATE_STATUSES = %w[draft live].freeze
  MAX_PATTERNS = 20
  MAX_PATTERN_LENGTH = 256
  ICON_TYPES = %w[image/png image/jpeg image/webp].freeze
  ICON_MAX_BYTES = 1.megabyte
  COLOR_FORMAT = /\A#\h{6}\z/

  belongs_to :project
  belongs_to :default_link, class_name: "Link", optional: true
  has_many :smart_banner_links, dependent: :delete_all
  has_one_attached :icon

  scope :live, -> { where(status: "live") }
  scope :ordered, -> { order(:priority, :id) }

  validates :name, presence: true, length: { maximum: 100 }
  validates :title, presence: true, length: { maximum: 80 }
  validates :subtitle, length: { maximum: 120 }
  validates :button_text, presence: true, length: { maximum: 24 }
  validates :position, inclusion: { in: POSITIONS }
  validates :status, inclusion: { in: STATUSES }
  validates :background_color, :text_color, :button_color, :button_text_color, format: { with: COLOR_FORMAT }
  validates :dismiss_days, numericality: { only_integer: true, greater_than_or_equal_to: 0, less_than_or_equal_to: 365 }
  validates :open_hide_days, numericality: { only_integer: true, greater_than_or_equal_to: 0, less_than_or_equal_to: 365 }
  validate :platforms_valid, :patterns_valid, :icon_valid
  validate :status_create_restricted, on: :create
  after_commit :clear_sdk_cache

  def link_ids
    [default_link_id, *smart_banner_links.pluck(:link_id)].compact
  end

  def self.reserved_tag?(tag)
    tag.to_s == LINK_TAG || tag.to_s.start_with?("#{LINK_TAG}:")
  end

  def self.without_reserved_tags(tags)
    tags.is_a?(Array) ? tags.reject { |tag| reserved_tag?(tag) } : tags
  end

  def self.sdk_version_key(project_id)
    "smart_banners:version:#{project_id}"
  end

  # Versioned so a payload computed before a change is written under a key no reader uses any more.
  def self.sdk_cache_key(project_id)
    "smart_banners:sdk:v1:#{project_id}:#{Rails.cache.read(sdk_version_key(project_id), raw: true).to_i}"
  end

  def self.sdk_payload_for(project)
    Rails.cache.fetch(sdk_cache_key(project.id), expires_in: 10.minutes) do
      project.smart_banners.live.ordered.includes(default_link: :domain, icon_attachment: :blob)
             .filter_map { |banner| SmartBannerSerializer.sdk(banner) }
    end
  end

  private

  def clear_sdk_cache
    Rails.cache.increment(self.class.sdk_version_key(project_id))
  end

  def platforms_valid
    errors.add(:platforms, "must include ios, android or both") if platforms.blank? || (platforms - PLATFORMS).any?
  end

  def patterns_valid
    { url_include: url_include, url_exclude: url_exclude }.each do |attr, patterns|
      errors.add(attr, "can have at most #{MAX_PATTERNS} patterns") if patterns.size > MAX_PATTERNS
      next if patterns.all? { |p| p.start_with?("/") && p.length <= MAX_PATTERN_LENGTH }

      errors.add(attr, "patterns must start with / and be at most #{MAX_PATTERN_LENGTH} characters")
    end
  end

  def icon_valid
    return unless icon.attached?

    errors.add(:icon, "must be PNG, JPEG or WebP") unless ICON_TYPES.include?(icon.blob.content_type)
    errors.add(:icon, "must be at most 1 MB") if icon.blob.byte_size > ICON_MAX_BYTES
  end

  def status_create_restricted
    errors.add(:status, "must be draft or live on create") unless CREATE_STATUSES.include?(status)
  end
end
