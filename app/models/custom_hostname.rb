require "public_suffix"

class CustomHostname < ApplicationRecord
  include ModelCachingExtension

  STATUSES = %w[provisioning pending active suspended failed].freeze

  SOURCE_SAAS = "saas"
  SOURCE_ENTERPRISE = "enterprise"
  SOURCES = [SOURCE_SAAS, SOURCE_ENTERPRISE].freeze

  # Reattributing a migration row to primary while a MigrationSource references it produces
  # resolver/validator inconsistency. Under Rails 8.1 this raises ReadonlyAttributeError.
  attr_readonly :purpose

  belongs_to :project
  belongs_to :domain

  before_validation :normalize_hostname
  # An orphaned MigrationSource would (a) fail custom_hostname_still_active? on resolve
  # and (b) hold the globally-unique old_host index against any reclaim.
  after_destroy :cleanup_orphaned_migration_source

  validates :hostname, presence: true, uniqueness: true
  validates :status, inclusion: { in: STATUSES }
  validates :source, inclusion: { in: SOURCES }
  validates :purpose, inclusion: { in: Grovs::Hostnames::PURPOSES }
  validate  :hostname_is_valid_subdomain

  scope :saas, -> { where(source: SOURCE_SAAS) }
  scope :primary, -> { where(purpose: Grovs::Hostnames::PURPOSE_PRIMARY) }
  scope :migration, -> { where(purpose: Grovs::Hostnames::PURPOSE_MIGRATION) }

  def resolvable?
    status == "active"
  end

  # Row state, not env state, so a CLOUDFLARE_* change never reinterprets existing rows.
  def cloudflare?
    cf_custom_hostname_id.present? || status == "provisioning"
  end

  def manual?
    !cloudflare?
  end

  def saas?
    source == SOURCE_SAAS
  end

  def enterprise?
    source == SOURCE_ENTERPRISE
  end

  def primary?
    purpose == Grovs::Hostnames::PURPOSE_PRIMARY
  end

  def migration?
    purpose == Grovs::Hostnames::PURPOSE_MIGRATION
  end

  def cache_keys_to_clear
    keys = super
    prefix = self.class.cache_prefix
    keys << "#{prefix}:find_by:hostname:#{hostname}:no_includes" if hostname.present?
    if previous_changes.key?("hostname") && (old = previous_changes["hostname"][0]).present?
      keys << "#{prefix}:find_by:hostname:#{old}:no_includes"
    end
    keys
  end

  private

  def cleanup_orphaned_migration_source
    MigrationSource.where(project_id: project_id, old_host: hostname).destroy_all
  rescue StandardError => e
    Rails.logger.warn(message: "custom_hostname_cleanup_migration_source_failed",
                      hostname: hostname, project_id: project_id, error: e.message)
  end

  def normalize_hostname
    self.hostname = hostname.to_s.strip.downcase.delete_suffix(".") if hostname.present?
  end

  def hostname_is_valid_subdomain
    return if hostname.blank?

    # Cloudflare for SaaS requires punycode; raw Unicode would be non-resolvable.
    unless hostname.ascii_only?
      errors.add(:hostname, "must use ASCII (punycode) encoding")
      return
    end

    parsed = PublicSuffix.parse(hostname)
    errors.add(:hostname, "must be a subdomain") if parsed.trd.blank?
    errors.add(:hostname, "is reserved") if LinksService.deployment_host?(hostname.to_s.downcase)
  rescue PublicSuffix::Error
    errors.add(:hostname, "is invalid")
  end
end
