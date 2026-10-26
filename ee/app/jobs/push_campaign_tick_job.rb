class PushCampaignTickJob
  include Sidekiq::Job
  sidekiq_options queue: :maintenance, retry: 0

  STALE_CLAIM = 10.minutes
  STALE_EVALUATING = 45.minutes # longer than the longest busy wait (30 min +25%), so a retry is never duplicated
  STALE_QUEUED = 10.minutes
  RECONCILE_ROUNDS = 20 # of 1,000 rows: a DB blip during a big campaign leaves far more than one round

  # Per campaign so both queries lead with push_campaign_id and hit the claim index.
  def perform
    release_due
    revive_evaluating
    RECONCILE_ROUNDS.times { break if PushDelivery.reconcile_queued!(older_than: STALE_QUEUED.ago).zero? }
    Experiments::Winner.due
    PushCampaign.sending.pluck(:id).each do |id|
      rows = PushDelivery.where(push_campaign_id: id)
      rows.where(status: "claimed").where("updated_at < ?", STALE_CLAIM.ago).update_all(status: "pending", updated_at: Time.current)
      next unless rows.where(status: "pending").where("due_at <= ?", Time.current).exists?

      PushCampaignEvaluateJob::PARALLELISM.times { |slot| PushCampaignDeliverJob.perform_async(id, slot) }
    end
  end

  private

  # Local-time campaigns are released early so the easternmost devices are frozen before they come due.
  def release_due
    PushCampaign.where(status: "scheduled")
                .where("scheduled_at - (CASE WHEN local_time THEN make_interval(secs => ?) ELSE interval '0' END) <= ?",
                       PushCampaign::MAX_LOCAL_TIME_LEAD.to_i, Time.current)
                .find_each do |campaign|
      next if campaign.release_at > Time.current
      next unless campaign.transition!(from: %w[scheduled], to: "evaluating", started_at: Time.current)

      PushCampaignEvaluateJob.perform_async(campaign.id)
    rescue ActiveRecord::RecordInvalid
      # The snapshot's segment was archived meanwhile; this campaign fails, the rest of the loop goes on.
      campaign.update_columns(status: "failed", failure_reason: "segment_invalid", finished_at: Time.current, updated_at: Time.current)
      Audit.record(instance_id: campaign.project.instance_id, action: "push_campaign.failed", actor: AuditActor.system(self.class.name),
                   target: Audit.target_for(campaign), changes: { "after" => { "failure_reason" => "segment_invalid" } })
    end
  end

  # An enqueue that never happened (Redis blip after the status write) would otherwise strand the campaign.
  def revive_evaluating
    PushCampaign.where(status: "evaluating").where(updated_at: ...STALE_EVALUATING.ago).pluck(:id).each do |id|
      PushCampaignEvaluateJob.perform_async(id)
    end
  end
end
