class InAppMembershipRefreshJob
  include Sidekiq::Job
  sidekiq_options queue: :egress_exports, retry: 0

  SKIP = [Segments::Busy, Segments::ResultExpired, Clickhouse::Unavailable, InAppMemberships::Locked,
          Segments::InvalidDefinition, Segments::WindowExpired, Analytics::QueryTooHeavy].freeze

  # Without arguments it fans out, one job per tracked segment; a failed one keeps its rows until the next run.
  def perform(campaign_id = nil, journey_id = nil)
    return unless Grovs.in_app_enabled?
    return Journeys.refresh_segments(journey_id) if journey_id
    return fan_out if campaign_id.nil?

    campaign = InAppCampaign.where(status: %w[scheduled live paused]).where.not(audience_type: "journey").find_by(id: campaign_id)
    InAppMemberships.refresh(campaign) if campaign&.segment_key
  rescue *SKIP => e
    Rails.logger.warn("in_app.membership_refresh_skipped campaign=#{campaign_id} journey=#{journey_id} #{e.class}")
    Grovs::Metrics.increment("in_app.membership_refresh_skipped", tags: { reason: e.class.name })
  end

  private

  def fan_out
    InAppCampaign.where(status: %w[scheduled live paused]).where.not(segment_key: nil).where.not(audience_type: "journey")
                 .group(:segment_key).minimum(:id).each_value { |id| self.class.perform_async(id) }
    Journey.where(status: Journey::STATUSES - ["draft"], finished_at: nil).where.not(segment_keys: {}).pluck(:id).each do |id|
      self.class.perform_async(nil, id)
    end
  end
end
