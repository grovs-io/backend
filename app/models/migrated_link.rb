# Per-slug resolver cache. Writes go through MigratedLink.upsert in FirstHitMigration —
# which bypasses after_commit, so callers explicitly invoke .invalidate_cache_for after
# each upsert to keep Redis consistent with the row.
class MigratedLink < ApplicationRecord
  include ModelCachingExtension

  belongs_to :migration_source
  belongs_to :link, optional: true  # nullable for negative-cache rows

  STATUS_RESOLVED        = "resolved"
  STATUS_NOT_FOUND       = "not_found"
  STATUS_TRANSIENT_ERROR = "transient_error"
  ALL_STATUSES = [STATUS_RESOLVED, STATUS_NOT_FOUND, STATUS_TRANSIENT_ERROR].freeze

  # Empty old_path is valid (host-root click `https://old.host/`).
  validates :status, inclusion: { in: ALL_STATUSES }
  validates :old_path, uniqueness: { scope: :migration_source_id }

  def cache_keys_to_clear
    keys = super
    if migration_source_id && old_path
      keys << multi_condition_cache_key(
        { migration_source_id: migration_source_id, old_path: old_path }
      )
    end
    keys
  end

  # Invalidation entry point for code paths that upsert without instantiating a record
  # (FirstHitMigration). Builds a transient AR object just to reach the cache_keys helper.
  def self.invalidate_cache_for(migration_source_id:, old_path:)
    transient = new(migration_source_id: migration_source_id, old_path: old_path)
    keys = transient.cache_keys_to_clear.uniq
    return if keys.empty?
    REDIS.with { |c| c.del(*keys) }
  rescue Redis::BaseError, StandardError => e
    # Silent failure here serves stale rows for up to the cache TTL — surface in metrics.
    Grovs::Metrics.increment("migration.cache.invalidate_failed",
                              tags: { source_id: migration_source_id })
    Rails.logger.warn(message: "migrated_link_cache_invalidate_failed",
                      source_id: migration_source_id, old_path: old_path, error: e.message)
  end
end
