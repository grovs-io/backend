class InAppMembershipPopulateJob
  include Sidekiq::Job
  sidekiq_options queue: :egress_exports, retry: 3

  BACKOFF_MINUTES = [1, 2, 4, 8, 15].freeze
  RETRY_LATER = [Segments::Busy, Segments::ResultExpired, Clickhouse::Unavailable, InAppMemberships::Locked].freeze
  INVALID = [Segments::InvalidDefinition, Segments::WindowExpired, Analytics::QueryTooHeavy].freeze

  sidekiq_retries_exhausted do |job, _ex|
    campaign = InAppCampaign.find_by(id: job["args"]&.first)
    back_to_draft(campaign, "audience_error") if campaign
  end

  # Saved unchecked: a campaign whose segment was deleted is not a valid draft, and must still leave preparing.
  def self.back_to_draft(campaign, reason)
    campaign.with_lock do
      next unless campaign.status == "preparing"

      campaign.assign_attributes(status: "draft", failure_reason: reason, launched_at: nil, segment_key: nil)
      campaign.save!(validate: false)
    end
  end

  def perform(campaign_id, attempt = 0)
    return unless Grovs.in_app_enabled?

    campaign = InAppCampaign.find_by(id: campaign_id, status: "preparing")
    return if campaign.nil?

    # Another campaign may already be served from these rows; its devices must hear of every change to them.
    shared = InAppCampaign.served.where(segment_key: campaign.segment_key).where.not(id: campaign.id).exists?
    InAppMemberships.refresh(campaign, announce: shared)
    campaign.go_live!
  rescue *RETRY_LATER
    # So the tick sees a campaign that is being worked on. No callback: devices have nothing new to fetch.
    campaign.update_column(:updated_at, Time.current)
    wait = BACKOFF_MINUTES[attempt]
    return self.class.back_to_draft(campaign, "audience_busy") if wait.nil?

    self.class.perform_in((wait * rand(0.75..1.25)).minutes, campaign_id, attempt + 1)
  rescue *INVALID
    self.class.back_to_draft(campaign, "segment_invalid")
  end
end
