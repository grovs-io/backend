# Daily cleanup of stale negative-cache rows. Without this, a bot scanning many unique
# paths grows migrated_links unboundedly. Resolved rows are kept (deleting them forces
# upstream re-resolution).
class MigratedLinkCleanupJob < ApplicationJob
  queue_as :maintenance

  GRACE_WINDOW = 7.days
  BATCH_SIZE   = 10_000

  def perform
    cutoff = GRACE_WINDOW.ago
    deleted = MigratedLink.where(status: [MigratedLink::STATUS_NOT_FOUND,
                                          MigratedLink::STATUS_TRANSIENT_ERROR])
                          .where("cached_until < ?", cutoff)
                          .in_batches(of: BATCH_SIZE)
                          .delete_all
    Rails.logger.info(message: "migrated_link_cleanup", deleted: deleted, cutoff: cutoff)
    Grovs::Metrics.increment("migration.cleanup.rows_deleted", by: deleted)
    deleted
  end
end
