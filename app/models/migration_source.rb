class MigrationSource < ApplicationRecord
  include ModelCachingExtension

  belongs_to :project
  has_many :migrated_links, dependent: :delete_all

  # Order matters: serialize before encrypts; reversing produces String reads instead of Hash.
  serialize :credentials, coder: JSON
  encrypts :credentials


  MAX_CONSECUTIVE_FAILURES = 500
  MAX_FAILURE_WINDOW       = 2.days
  DEGRADED_EMAIL_THRESHOLD = 1.hour
  DEGRADED_EMAIL_COOLDOWN  = 24.hours

  validates :provider, inclusion: { in: Grovs::Migrations::MVP_PROVIDERS }
  validates :old_host, presence: true, uniqueness: true,
            format: {
              with: /\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+\z/,
              message: "must be a valid bare hostname (no scheme, no port, no path)"
            }
  validate :credentials_shape_for_provider
  validate :custom_hostname_exists_for_project

  before_validation :normalize_old_host
  before_update :reset_counters_if_credentials_or_enabled_changed

  def cache_keys_to_clear
    keys = super
    prefix = self.class.cache_prefix
    keys << "#{prefix}:find_by:old_host:#{old_host}:no_includes" if old_host.present?
    if previous_changes.key?("old_host") && (prev = previous_changes["old_host"][0]).present?
      keys << "#{prefix}:find_by:old_host:#{prev}:no_includes"
    end
    keys
  end

  def health
    return :disabled unless enabled
    return :healthy  if consecutive_failures.zero?
    :degraded
  end

  # Atomic UPDATE so concurrent failures don't lose increments. update_all bypasses
  # after_commit; invalidate_cache! handles it manually.
  def record_failure!(status_code)
    now = Time.current
    self.class.where(id: id).update_all([
      "consecutive_failures = consecutive_failures + 1, " \
      "first_failure_at = COALESCE(first_failure_at, ?), " \
      "last_error_status = ?, " \
      "updated_at = ?",
      now, status_code, now
    ])
    reload
    invalidate_cache!
    notify_degraded_if_threshold_crossed!
    disable_with_notification! if exhausted?
  end

  # degraded_email_sent_at is cleared separately after DEGRADED_EMAIL_COOLDOWN so a flapping
  # source doesn't re-fire the email on every recovery.
  def record_success!
    affected = self.class.where(id: id)
                         .where("consecutive_failures > 0 OR first_failure_at IS NOT NULL OR last_error_status IS NOT NULL")
                         .update_all(
                           consecutive_failures: 0, first_failure_at: nil,
                           last_error_status: nil,
                           updated_at: Time.current
                         )
    clear_degraded_gate_if_cooled_down
    return if affected.zero?
    reload
    invalidate_cache!
  end

  def exhausted?
    consecutive_failures >= MAX_CONSECUTIVE_FAILURES ||
      (first_failure_at && first_failure_at < MAX_FAILURE_WINDOW.ago)
  end

  # nil when an admin disabled via PATCH; set by disable_with_notification! on auto-disable.
  # Resolver branches cache-miss behavior on this.
  def auto_disabled?
    !enabled && auto_disabled_at.present?
  end

  private

  def clear_degraded_gate_if_cooled_down
    return if degraded_email_sent_at.nil?
    return if degraded_email_sent_at > DEGRADED_EMAIL_COOLDOWN.ago
    affected = self.class.where(id: id)
                         .where("degraded_email_sent_at IS NOT NULL AND degraded_email_sent_at <= ?", DEGRADED_EMAIL_COOLDOWN.ago)
                         .update_all(degraded_email_sent_at: nil, updated_at: Time.current)
    return if affected.zero?
    reload
    invalidate_cache!
  end

  def normalize_old_host
    return if old_host.blank?
    self.old_host = old_host.to_s.strip.downcase.chomp(".").sub(/:\d+\z/, "")
  end

  def reset_counters_if_credentials_or_enabled_changed
    credentials_changed = will_save_change_to_credentials?
    enabled_flipped_on  = will_save_change_to_enabled? && enabled

    return unless credentials_changed || enabled_flipped_on

    self.consecutive_failures   = 0
    self.first_failure_at       = nil
    self.last_error_status      = nil
    self.degraded_email_sent_at = nil

    self.auto_disabled_at = nil if enabled_flipped_on

    # Credentials rotation on an auto-disabled source means "I fixed auth" — re-enable.
    # Admin-disabled sources (auto_disabled_at nil) stay disabled.
    if credentials_changed && !enabled && auto_disabled_at.present?
      self.enabled = true
      self.auto_disabled_at = nil
    end
  end

  def credentials_shape_for_provider
    required = case provider
               when Grovs::Migrations::PROVIDER_BRANCH    then %w[branch_key]
               when Grovs::Migrations::PROVIDER_APPSFLYER then %w[onelink_id api_token]
               end
    return if required.blank?
    missing = required - (credentials || {}).keys.map(&:to_s)
    errors.add(:credentials, "missing keys: #{missing.join(', ')}") if missing.any?
  end

  # Does NOT require ch.resolvable? — the combined POST /migrations endpoint creates both
  # records in one transaction with CH typically still "pending". Runtime safety lives in
  # MigrationResolver.custom_hostname_still_active?, which gates inbound clicks.
  # Cross-project ownership is a controller-layer 409, not a validation error.
  def custom_hostname_exists_for_project
    return if old_host.blank? || project_id.blank?
    ch = CustomHostname.redis_find_by(:hostname, old_host)
    ch = nil if ch && ch.project_id != project_id

    if ch.nil?
      errors.add(:old_host,
        "must first be added as a migration-purpose custom domain on this project " \
        "(POST /api/v1/projects/:id/custom_domains with purpose: \"migration\")")
    elsif !ch.migration?
      errors.add(:old_host,
        "is the project's primary custom domain — migration must use a separate " \
        "purpose=\"migration\" custom domain")
    elsif ch.status == "suspended"
      # Mid-teardown: closes the race where validation passes against a CH about to disappear.
      errors.add(:old_host, "custom domain is being removed; retry shortly")
    end
  end

  # Atomic conditional UPDATE — only one racing worker enqueues.
  def notify_degraded_if_threshold_crossed!
    return if first_failure_at.nil? || first_failure_at > DEGRADED_EMAIL_THRESHOLD.ago
    now = Time.current
    affected = self.class.where(id: id, degraded_email_sent_at: nil)
                         .update_all(degraded_email_sent_at: now, updated_at: now)
    return if affected.zero?
    invalidate_cache!
    # Snapshot at enqueue — by Sidekiq render time the source may have recovered.
    MigrationMailer.degraded_warning(MigrationMailer.snapshot_for(self)).deliver_later
  end

  # Sets auto_disabled_at so a later credentials PATCH can distinguish auto- from admin-disable.
  def disable_with_notification!
    now = Time.current
    affected = self.class.where(id: id, enabled: true)
                         .update_all(enabled: false, auto_disabled_at: now, updated_at: now)
    return if affected.zero?
    reload
    invalidate_cache!
    MigrationMailer.credentials_invalid(MigrationMailer.snapshot_for(self)).deliver_later
  end

  # update_all bypasses after_commit; mirrors UpdateDeviceJob's manual-invalidation pattern.
  def invalidate_cache!
    keys = cache_keys_to_clear
    return if keys.empty?
    REDIS.with { |c| c.del(*keys) }
  end
end
