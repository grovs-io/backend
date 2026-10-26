# Deletes a removed rpush app's sent rows (payloads, tokens); CE has no EE purge job.
class RpushAppHistoryPurgeJob
  include Sidekiq::Job
  sidekiq_options queue: :maintenance, retry: 3

  BATCH = 10_000
  AGAIN_AFTER = 1.hour # rows still in flight at removal settle later

  def perform(app_id, pass = 1)
    return if Rpush::Client::ActiveRecord::App.exists?(app_id)

    rows = Rpush::Client::ActiveRecord::Notification.where(app_id: app_id).where("delivered OR failed")
    loop do
      batch = rows.limit(BATCH).to_a
      break if batch.empty?

      Rpush::Client::ActiveRecord::Notification.transaction do
        PushOutcomes.settle(batch)
        Rpush::Client::ActiveRecord::Notification.where(id: batch.map(&:id)).delete_all
      end
    end
    self.class.perform_in(AGAIN_AFTER, app_id, 2) if pass == 1
  end
end
