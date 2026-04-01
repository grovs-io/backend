class MergeVisitorEventsJob
  include Sidekiq::Job
  sidekiq_options queue: :events, retry: 1

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

    from_visitor = from_device.visitor_for_project_id(project.id)
    if from_visitor.nil?
      Rails.logger.warn("From Visitor not found for merging events, nothing to merge")
      return
    end

    to_visitor = Visitor.find_or_create_by!(device: to_device, project: project)

    ActiveRecord::Base.transaction do
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

      # Clean up old visitor
      from_visitor.destroy
    end
  end
end