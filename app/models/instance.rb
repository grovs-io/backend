class Instance < ApplicationRecord
  include ModelCachingExtension
  include Hashid::Rails

  validates :uri_scheme, presence: true
  validates :api_key, presence: true

  validates :cold_storage_days, :delete_days,
            numericality: { only_integer: true, greater_than: 0 }
  validate :delete_days_not_below_cold_storage

  has_many :instance_roles, dependent: :delete_all
  has_many :users, through: :instance_roles
  has_many :setup_progress_steps, dependent: :delete_all

  has_many :applications

  has_one :test, -> {where(test: true)}, class_name: 'Project', dependent: :destroy
  has_one :production, -> {where(test: false)}, class_name: 'Project', dependent: :destroy
  # The seeded public go instance and rows mid-deletion lack a project; the dashboard cannot operate on them.
  scope :with_both_projects, -> { where(id: Project.where(test: true).select(:instance_id)).where(id: Project.where(test: false).select(:instance_id)) }

  has_one :ios_application, -> {where(platform: Grovs::Platforms::IOS)}, class_name: 'Application'
  has_one :android_application, -> {where(platform: Grovs::Platforms::ANDROID)}, class_name: 'Application'
  has_one :desktop_application, -> {where(platform: Grovs::Platforms::DESKTOP)}, class_name: 'Application'
  has_one :web_application, -> {where(platform: Grovs::Platforms::WEB)}, class_name: 'Application'

  before_destroy :execute_before_destroy

  has_many :stripe_subscriptions
  has_many :audit_export_tokens, dependent: :delete_all if defined?(AuditExportToken)
  has_one :sso_connection, dependent: :destroy if defined?(SsoConnection)
  has_many :stripe_payment_intents

  has_one :enterprise_subscription, dependent: :destroy

  # Methods
    
  # Query, not the has_one: a renewal leaves an inactive row beside the active one; has_one picks either.
  # end_date checked at read time — no job flips active when the term lapses.
  def valid_enterprise_subscription
    EnterpriseSubscription.where(instance_id: id, active: true)
                          .where("end_date >= ?", Time.current).first
  end

  # Explicit subscription checks so this does not depend on #subscription's paused behaviour.
  def custom_domains_entitled?
    return true if Grovs.self_hosted?

    stripe_subscriptions.exists?(active: true) || valid_enterprise_subscription.present?
  end

  def audit_log_enabled?
    return true if Grovs.self_hosted?

    valid_enterprise_subscription.present?
  end

  def enterprise_sso_enabled? = audit_log_enabled?

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
    # detect (not find_by) so a preloaded :stripe_subscriptions collection is used
    # in-memory — avoids per-instance N+1 when serializing instance lists.
    stripe_subscriptions.detect(&:active) ||
      stripe_subscriptions.detect { |s| !s.active && s.status == "paused" }
  end

  def link_for_path(path)
    link = LinksService.find_link_preferring_active(production.domain.id, path)
    link ||= LinksService.find_link_preferring_active(test.domain.id, path)

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

  def delete_days_not_below_cold_storage
    return if delete_days.blank? || cold_storage_days.blank?

    errors.add(:delete_days, "must be >= cold_storage_days") if delete_days < cold_storage_days
  end

  def execute_before_destroy
    ios_application&.configuration&.destroy
    android_application&.configuration&.destroy
    desktop_application&.configuration&.destroy
    web_application&.configuration&.destroy

    applications = Application.where(instance_id: id)
    applications.destroy_all
  end

end
