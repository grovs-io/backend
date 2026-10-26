class Project < ApplicationRecord
  include ModelCachingExtension

  include Hashid::Rails

  validates :name, presence: true
  validates :identifier, presence: true, uniqueness: true

  has_many :smart_banners, dependent: :destroy
  has_one :redirect_config, dependent: :destroy
  has_one :domain, dependent: :destroy
  has_many :custom_hostnames, dependent: :destroy
  has_one :migration_source, dependent: :destroy
  has_many :event_destinations, dependent: :delete_all if defined?(EventDestination)
  has_many :segment_exports, dependent: :destroy if defined?(SegmentExport)
  has_many :segments, dependent: :delete_all if defined?(Segment)
  has_many :push_campaigns, dependent: :delete_all if defined?(PushCampaign)
  has_many :in_app_campaigns, dependent: :delete_all if defined?(InAppCampaign)
  has_many :journeys, dependent: :delete_all if defined?(Journey)
  has_many :event_stream_tokens, dependent: :delete_all if defined?(EventStreamToken)

  has_many :events, dependent: :delete_all

  belongs_to :instance

  has_many :visitors, dependent: :destroy


  has_many :installed_apps, dependent: :destroy 
  has_many :campaigns, dependent: :destroy
  has_many :dashboards, dependent: :destroy
  has_many :visitor_last_visits, dependent: :delete_all

  def domain_for_project
    domain
  end

  def test?
    self[:test]
  end

  def cache_keys_to_clear
    keys = super
    prefix = self.class.cache_prefix
    keys << "#{prefix}:find_by:identifier:#{identifier}:includes:instance" if respond_to?(:identifier) && identifier.present?
    keys
  end

  private


end
