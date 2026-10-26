class PushCampaignPurgeJob
  include Sidekiq::Job
  sidekiq_options queue: :maintenance, retry: 0

  DELIVERY_RETENTION = 30.days
  RPUSH_RETENTION = 7.days
  BATCH = 50_000
  MAX_BATCHES = 20 # bounded per night on the shared maintenance worker; leftovers wait a day

  def perform
    budget = MAX_BATCHES
    # People still waiting for a winner go with the rows: nobody can be sent to once they are gone.
    PushCampaign.where(finished_at: ...DELIVERY_RETENTION.ago).where("waiting > 0").update_all(waiting: 0, winner_due_at: nil, updated_at: Time.current)
    PushCampaign.where(finished_at: ...DELIVERY_RETENTION.ago).where(id: PushDelivery.select(:push_campaign_id)).pluck(:id).each do |id|
      while budget.positive?
        budget -= 1
        break if PushDelivery.where(push_campaign_id: id).limit(BATCH).delete_all.zero?
      end
    end
    purge_journey_rows
    budget = MAX_BATCHES
    while budget.positive?
      budget -= 1
      break if Rpush::Notification.where("(delivered OR failed) AND created_at < ?", RPUSH_RETENTION.ago).limit(BATCH).delete_all.zero?
    end
  end

  # A journey's campaigns never finish, so their rows go by age instead.
  def purge_journey_rows
    MAX_BATCHES.times do
      ids = PushDelivery.where.not(journey_person_id: nil).where(created_at: ...DELIVERY_RETENTION.ago).limit(BATCH).pluck(:id)
      break if ids.empty?

      PushDelivery.where(id: ids).delete_all
    end
  end
end
