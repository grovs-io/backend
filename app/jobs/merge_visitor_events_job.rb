class MergeVisitorEventsJob
  include Sidekiq::Job
  sidekiq_options queue: :events, retry: 2

  def perform(from_device_id, to_device_id, project_id)
    from_device = Device.find_by(id: from_device_id)
    to_device = Device.find_by(id: to_device_id)
    project = Project.find_by(id: project_id)

    if !from_device || !to_device || !project
      Rails.logger.warn("Project, From Device or To Device not found for merging events")
      return
    end

    # Ensure installed app exists for both devices
    [from_device, to_device].each do |device|
      InstalledApp.find_or_create_by!(device_id: device.id, project_id: project.id)
    end

    cache_keys = nil

    ActiveRecord::Base.transaction do
      conn = ActiveRecord::Base.lease_connection
      conn.execute("SET LOCAL statement_timeout = '10s'")

      # Under READ COMMITTED, if a concurrent job already destroyed this
      # visitor and committed, find_by returns nil — no explicit lock needed.
      # CoalescedMergeJob serializes merges per target via Redis processing lock.
      from_visitor = Visitor.find_by(device_id: from_device.id, project_id: project.id)
      unless from_visitor
        Rails.logger.warn("From Visitor not found for merging events, nothing to merge")
        return
      end

      to_visitor = Visitor.find_or_create_by!(device: to_device, project: project)

      # Update inviter if needed
      if to_visitor.inviter_id.nil? && from_visitor.inviter_id.present?
        to_visitor.inviter_id = from_visitor.inviter_id
        to_visitor.save!
      end

      # Merge actions, links and events in bulk
      from_device.actions.update_all(device_id: to_device.id)
      from_visitor.links.update_all(visitor_id: to_visitor.id)
      from_device.events.update_all(device_id: to_device.id,  platform: to_device.platform)

      # Merge the metrics
      VisitorDailyStatistic.merge_visitors!(from_id: from_visitor.id, to_id: to_visitor.id)

      # Transfer last-visit attribution (keep the most recent one)
      from_vlv = VisitorLastVisit.find_by(project_id: project.id, visitor_id: from_visitor.id)
      if from_vlv
        to_vlv = VisitorLastVisit.find_by(project_id: project.id, visitor_id: to_visitor.id)
        if to_vlv.nil? || from_vlv.updated_at > to_vlv.updated_at
          VisitorLastVisit.connection.execute(
            VisitorLastVisit.sanitize_sql_array([
              "INSERT INTO visitor_last_visits (project_id, visitor_id, link_id, created_at, updated_at) " \
              "VALUES (?, ?, ?, NOW(), NOW()) " \
              "ON CONFLICT (project_id, visitor_id) DO UPDATE SET link_id = EXCLUDED.link_id, updated_at = EXCLUDED.updated_at",
              project.id, to_visitor.id, from_vlv.link_id
            ])
          )
        end
        from_vlv.delete
      end

      # Clean up old visitor — bulk-delete the heavy children first to avoid
      # N+1 callback overhead (notification_messages has no callbacks).
      # visitor_daily_statistics and visitor_last_visits already handled above.
      NotificationMessage.where(visitor_id: from_visitor.id).delete_all

      # Repoint referral attribution from from_visitor → to_visitor.
      # invited_by_id has no index on the 50GB visitor_daily_statistics table, so
      # querying by it directly causes a 10s+ full table scan. Instead, find invited
      # visitors from the small visitors table, then use idx_vds_visitor_id to update
      # their stats — fast indexed lookups only.
      invited_visitor_ids = Visitor.where(inviter_id: from_visitor.id).pluck(:id)
      if invited_visitor_ids.any?
        VisitorDailyStatistic.where(visitor_id: invited_visitor_ids, invited_by_id: from_visitor.id)
                             .update_all(invited_by_id: to_visitor.id)
      end
      Visitor.where(inviter_id: from_visitor.id).update_all(inviter_id: to_visitor.id)

      # Use delete (not destroy) to skip dependent: :nullify on referral_daily_statistics
      # which would scan the 50GB table by unindexed invited_by_id. All dependents are
      # already cleaned up above. Manually clear Redis cache after commit.
      cache_keys = from_visitor.cache_keys_to_clear
      from_visitor.delete
    end

    # Clear Redis lookup caches after transaction commits (mirrors after_commit :clear_cache)
    REDIS.del(*cache_keys) if cache_keys.present?
  end
end
