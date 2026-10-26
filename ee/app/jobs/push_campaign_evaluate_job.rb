class PushCampaignEvaluateJob
  include Sidekiq::Job
  sidekiq_options queue: :push, retry: 5

  # SKIP LOCKED claimers per campaign; one hands off ~700–1,200/s, which HTTP/2 FCM outruns.
  PARALLELISM = Integer(ENV.fetch("PUSH_DELIVERY_PARALLELISM", 6)).clamp(1, 8)
  # Minutes before attempt n (±25% jitter): about three hours of patience before segment_busy.
  BACKOFF_MINUTES = [1, 2, 4, 8, 15, 30, 30, 30, 30].freeze
  MAX_BUSY_ATTEMPTS = BACKOFF_MINUTES.size + 1
  # A ClickHouse blip must not kill a scheduled send, so it waits like a busy permit does.
  RETRY_LATER = [Segments::Busy, Segments::ResultExpired, Clickhouse::Unavailable].freeze
  INVALID = [Segments::InvalidDefinition, Segments::WindowExpired, ActiveRecord::RecordNotFound].freeze

  sidekiq_retries_exhausted do |job, ex|
    campaign = PushCampaign.find_by(id: job["args"]&.first)
    Rails.logger.error("push_campaign.evaluation_failed id=#{campaign&.id} #{ex&.class}: #{ex&.message}")
    fail!(campaign, "evaluation_error") if campaign
  end

  def self.backoff(attempt)
    minutes = BACKOFF_MINUTES[attempt - 1] || BACKOFF_MINUTES.last
    (minutes * rand(0.75..1.25)).minutes
  end

  def self.fail!(campaign, reason)
    return false unless campaign.transition!(from: %w[evaluating], to: "failed", failure_reason: reason, finished_at: Time.current)

    Audit.record(instance_id: campaign.project.instance_id, action: "push_campaign.failed", actor: AuditActor.system(name),
                 target: Audit.target_for(campaign), changes: { "after" => { "failure_reason" => reason } })
    true
  end

  def perform(campaign_id)
    campaign = PushCampaign.find_by(id: campaign_id, status: "evaluating")
    return if campaign.nil?

    freeze_and_start(campaign)
  rescue *RETRY_LATER
    campaign.increment!(:busy_attempts, touch: true)
    return self.class.perform_in(self.class.backoff(campaign.busy_attempts), campaign_id) if campaign.busy_attempts < MAX_BUSY_ATTEMPTS

    self.class.fail!(campaign, "segment_busy")
  rescue *INVALID
    self.class.fail!(campaign, "segment_invalid")
  rescue Analytics::QueryTooHeavy
    self.class.fail!(campaign, "query_too_heavy")
  end

  private

  def freeze_and_start(campaign)
    return unless PushCampaigns::Evaluate.call(campaign)

    PARALLELISM.times { |slot| PushCampaignDeliverJob.perform_async(campaign.id, slot) }
  end
end
