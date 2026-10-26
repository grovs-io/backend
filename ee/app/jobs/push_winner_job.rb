class PushWinnerJob
  include Sidekiq::Job
  sidekiq_options queue: :maintenance, retry: 0

  def perform(campaign_id)
    campaign = PushCampaign.find_by(id: campaign_id, status: "sent")
    return if campaign.nil? || campaign.waiting.zero? || campaign.winner_due_at.nil? || campaign.winner_due_at > Time.current

    Experiments::Winner.send_to_rest(campaign)
  rescue StandardError => e
    Rails.logger.error("push_winner.failed #{campaign_id} #{e.class}: #{e.message}")
  end
end
