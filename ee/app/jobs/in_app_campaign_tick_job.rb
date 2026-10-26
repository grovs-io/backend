class InAppCampaignTickJob
  include Sidekiq::Job
  sidekiq_options queue: :maintenance, retry: 0

  # Longer than the longest wait between two attempts, so only a lost job looks stale.
  STALE_PREPARING = 25.minutes
  GIVE_UP = 45.minutes

  # Devices apply start and end themselves, so these writes leave the callback and updated_at alone: nobody is sent to sync.
  def perform
    return unless Grovs.in_app_enabled?

    now = Time.current
    due = InAppCampaign.where(status: %w[scheduled live paused]).where(end_at: ..now)
    keys = due.where.not(segment_key: nil).distinct.pluck(:segment_key)
    due.update_all(status: "ended", ended_at: now)
    InAppMembershipCleanupJob.perform_async(keys) if keys.any?
    InAppCampaign.where(status: "scheduled").where(start_at: ..now).update_all(status: "live")
    revive_preparing
    heal_stamps
  end

  HEAL_WINDOW = 1.hour

  private

  # A stamp Redis failed to take is written again here, so a paused campaign cannot stay on devices.
  def heal_stamps
    changed = InAppCampaign.where(updated_at: HEAL_WINDOW.ago..).where.not(status: %w[draft preparing]).group(:project_id).maximum(:updated_at)
    InAppSetting.where(updated_at: HEAL_WINDOW.ago..).pluck(:project_id, :updated_at).each do |project, at|
      changed[project] = [changed[project], at].compact.max
    end
    changed.each do |project, at|
      InAppStamps.touch_campaigns(project) if InAppStamps.campaigns(project).to_i < (at.to_f * 1000).to_i
    end
  end

  # An enqueue that never happened would otherwise leave the campaign preparing for ever.
  def revive_preparing
    InAppCampaign.where(status: "preparing").where(updated_at: ...STALE_PREPARING.ago).find_each do |campaign|
      next InAppMembershipPopulateJob.back_to_draft(campaign, "audience_busy") if campaign.launched_at < GIVE_UP.ago

      InAppMembershipPopulateJob.perform_async(campaign.id)
    rescue StandardError => e
      # One campaign that cannot be saved must not stop the ones after it.
      Rails.logger.error("in_app.revive_failed campaign=#{campaign.id} #{e.class}")
    end
  end
end
