class Instance < ApplicationRecord
  include ModelCachingExtension
  include Hashid::Rails

  validates :uri_scheme, presence: true
  validates :api_key, presence: true

  has_many :instance_roles, dependent: :delete_all
  has_many :users, through: :instance_roles
  has_many :setup_progress_steps, dependent: :delete_all

  has_many :applications

  has_one :test, -> {where(test: true)}, class_name: 'Project', dependent: :destroy
  has_one :production, -> {where(test: false)}, class_name: 'Project', dependent: :destroy

  has_one :ios_application, -> {where(platform: Grovs::Platforms::IOS)}, class_name: 'Application'
  has_one :android_application, -> {where(platform: Grovs::Platforms::ANDROID)}, class_name: 'Application'
  has_one :desktop_application, -> {where(platform: Grovs::Platforms::DESKTOP)}, class_name: 'Application'
  has_one :web_application, -> {where(platform: Grovs::Platforms::WEB)}, class_name: 'Application'

  before_destroy :execute_before_destroy

  has_many :stripe_subscriptions
  has_many :stripe_payment_intents

  has_one :enterprise_subscription, dependent: :nullify

  # Methods
    
  def valid_enterprise_subscription
    if enterprise_subscription && enterprise_subscription.active
      enterprise_subscription
    end
  end

  def application_for_platform(platform)
    application = Application.redis_find_by_multiple_conditions({ instance_id: id, platform: platform })
    application ||= Application.create(instance_id: id, platform: platform)

    application
  end

  def create_desktop_configuration
    desktop = application_for_platform(Grovs::Platforms::DESKTOP)
    desktop_configuration = desktop.desktop_configuration
    unless desktop_configuration
      desktop_configuration = DesktopConfiguration.new
      desktop_configuration.application = desktop_application
      desktop_configuration.save!
    end
  end

  def subscription
    active = stripe_subscriptions.find_by(active: true)
    if active
      # the active one
      return active
    end
  
    stripe_subscriptions.find_by(active: false, status: "paused")
  
    # latest one
  end

  def link_for_path(path)
    link = Link.redis_find_by_multiple_conditions({ domain_id: production.domain.id, path: path })
    link ||= Link.redis_find_by_multiple_conditions({ domain_id: test.domain.id, path: path })

    link
  end

  def cache_keys_to_clear
    keys = super
    prefix = self.class.cache_prefix
    keys << "#{prefix}:find_by:uri_scheme:#{uri_scheme}:no_includes" if respond_to?(:uri_scheme) && uri_scheme.present?
    if previous_changes.key?('uri_scheme') && previous_changes['uri_scheme'][0].present?
      keys << "#{prefix}:find_by:uri_scheme:#{previous_changes['uri_scheme'][0]}:no_includes"
    end

    # Clear project caches that embed this instance via `includes: :instance`.
    # Without this, toggling revenue_collection_enabled (or any instance field)
    # leaves a stale Project+Instance object in Redis for up to 5 minutes.
    project_prefix = Project.cache_prefix
    [test, production].each do |project|
      next unless project
      keys << "#{project_prefix}:find_by:identifier:#{project.identifier}:includes:instance"
    end

    keys
  end

  private

  def execute_before_destroy
    ios_application&.configuration&.destroy
    android_application&.configuration&.destroy
    desktop_application&.configuration&.destroy
    web_application&.configuration&.destroy

    applications = Application.where(instance_id: id)
    applications.destroy_all
  end

end
