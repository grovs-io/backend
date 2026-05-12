class OrphanedActionsCleanupJob
  include Sidekiq::Job
  sidekiq_options queue: :maintenance, retry: 3

  BATCH_SIZE = 1_000

  def perform
    total = 0

    loop do
      deleted = Action
        .where("NOT EXISTS (SELECT 1 FROM links WHERE links.id = actions.link_id)")
        .limit(BATCH_SIZE)
        .delete_all

      total += deleted
      break if deleted < BATCH_SIZE

      sleep(0.5)
    end

    Rails.logger.info("OrphanedActionsCleanupJob: purged #{total} orphaned actions") if total > 0
  end
end
