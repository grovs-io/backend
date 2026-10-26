# Moves a launched campaign to its segment as it is now. The old audience is served until the new one is written.
class InAppAudienceUpdateJob
  include Sidekiq::Job
  sidekiq_options queue: :egress_exports, retry: 5

  # Retrying cannot mend these; the campaign keeps its old audience and the button is offered again.
  PERMANENT = [InAppCampaign::Refused, Segments::InvalidDefinition, Segments::WindowExpired, Analytics::QueryTooHeavy].freeze

  def perform(campaign_id)
    return unless Grovs.in_app_enabled?

    campaign = InAppCampaign.where(status: %w[scheduled live paused]).find_by(id: campaign_id)
    return if campaign.nil? || campaign.segment&.archived?

    move(campaign)
  rescue *PERMANENT => e
    Rails.logger.warn("in_app.audience_update_refused campaign=#{campaign_id} #{e.class}")
    Grovs::Metrics.increment("in_app.audience_update_refused", tags: { reason: e.class.name })
  end

  private

  def move(campaign)
    snapshot = campaign.audience_snapshot
    return if snapshot.nil? || snapshot[:segment_key] == campaign.segment_key

    staged = campaign.dup
    staged.assign_attributes(snapshot)
    shared = InAppCampaign.served.exists?(segment_key: snapshot[:segment_key])
    old = campaign.segment_key
    InAppMemberships.refresh(staged, announce: shared) { campaign.update!(snapshot) }
    InAppMembershipCleanupJob.perform_async([old])
  end
end
