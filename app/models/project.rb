class Project < ApplicationRecord
  include ModelCachingExtension

  include Hashid::Rails

  validates :name, presence: true
  validates :identifier, presence: true, uniqueness: true

  has_one :redirect_config, dependent: :destroy
  has_one :domain, dependent: :destroy

  has_many :events, dependent: :delete_all

  belongs_to :instance

  has_many :visitors, dependent: :destroy

  has_many :notifications, dependent: :destroy

  has_many :installed_apps, dependent: :destroy 
  has_many :campaigns, dependent: :destroy
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
