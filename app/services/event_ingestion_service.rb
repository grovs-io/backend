class EventIngestionService

  class << self

    def log(type, project, device, data, link, engagement_time = nil, created_at: nil)
      event = event_for_params(type, project, device, data, link, engagement_time, created_at: created_at)

      add_invited_by_event_if_needed(type, device, link, event, project)
      update_event_visitor_if_needed(device, project)

      event.save!

      # Process event
      process_event(event)

      event
    end

    def log_event_without_view_duplicates(type, project, device, data, link, engagement_time = nil, created_at: nil)
      new_event = event_for_params(type, project, device, data, link, engagement_time, created_at: created_at)

      if new_event.event == Grovs::Events::VIEW
        # 5s dedup window: matches the Redis-based dedup in BatchEventProcessorJob.
        # This is the synchronous fallback path (used when Redis LPUSH fails);
        # same window ensures consistent dedup behavior regardless of code path.
        old_event = Event.where(event: new_event.event, device_id: new_event.device_id)
                        .where("created_at >= ?", 5.seconds.ago)
                        .order(created_at: :desc)
                        .first
        if old_event
          # we have an old invited by event update created at
          old_event.update_column(:created_at, Time.current)
          return old_event
        end
      end

      log(type, project, device, data, link, engagement_time, created_at: created_at)
    end

    def log_async(type, project, device, data, link, engagement_time = nil, created_at: nil)
      update_visitor_last_visit(project, device, link)
      enqueue_event(type, project, device, data, link, engagement_time, created_at: created_at)
    end

    private

    def update_visitor_last_visit(project, device, link)
      return unless link && device

      visitor = device.visitor_for_project_id(project.id)
      return unless visitor

      vlv = VisitorLastVisit.find_or_initialize_by(project_id: project.id, visitor_id: visitor.id)
      vlv.link_id = link.id
      vlv.save!
    rescue StandardError => e
      Rails.logger.error("update_visitor_last_visit failed: #{e.message}")
    end

    def enqueue_event(type, project, device, data, link, engagement_time, created_at: nil)
      timestamp = (created_at || Time.current).iso8601(3)
      payload = {
        type: type,
        project_id: project.id,
        device_id: device.id,
        data: data,
        link_id: link&.id,
        engagement_time: engagement_time,
        created_at: timestamp
      }.to_json

      REDIS.lpush(BatchEventProcessorJob::REDIS_KEY, payload)
    rescue Redis::BaseError => e
      Rails.logger.error("log_async Redis LPUSH failed, falling back to Sidekiq: #{e.class} - #{e.message}")
      fallback_to_sidekiq(type, project, device, data, link, engagement_time, timestamp, created_at: created_at)
    end

    def fallback_to_sidekiq(type, project, device, data, link, engagement_time, timestamp, created_at: nil)
      LogEventJob.perform_async(
        type,
        project.id,
        device.id,
        data,
        link&.id,
        engagement_time,
        timestamp
      )
    rescue Redis::BaseError => e
      Rails.logger.error("log_async Sidekiq fallback failed, falling back to sync: #{e.class} - #{e.message}")
      fallback_to_sync(type, project, device, data, link, engagement_time, created_at: created_at)
    end

    def fallback_to_sync(type, project, device, data, link, engagement_time, created_at: nil)
      log_event_without_view_duplicates(type, project, device, data, link, engagement_time, created_at: created_at)
    rescue StandardError => e
      Rails.logger.error("log_async sync fallback also failed, event lost: #{e.class} - #{e.message}")
    end

    def process_event(event)
      
      EventStatDispatchService.call_normal_event(event)
    rescue StandardError => e
      Rails.logger.error("Failed to process event #{event.id}: #{e.class} - #{e.message}")
      Rails.logger.error(e.backtrace.join("\n"))
      # Retry it on another queue
      ProcessNormalEventJob.perform_async(event.id)
      
    end

    def add_invited_by_event_if_needed(type, device, link, event, project)
      if type != Grovs::Events::INSTALL && type != Grovs::Events::REINSTALL
        return
      end

      return unless device && link

      visitor = device.visitor_for_project_id(project.id)
      return unless visitor && link.visitor

      unless visitor.inviter_id
        visitor.inviter_id = link.visitor.id
        visitor.save!
      end

      event.event = type
      event.project = project
      event.device = device
      event.link = link

      if link.visitor
        create_user_referred_event(project, link.visitor)
      end
    end

    def create_user_referred_event(project, visitor)
      return unless visitor.device

      event = Event.new
      event.event = Grovs::Events::USER_REFERRED
      event.project = project
      event.device = visitor.device
      event.save!

      # Process event
      process_event(event)
    end

    def update_event_visitor_if_needed(device, project)
      visitor = device&.visitor_for_project_id(project.id)
      if visitor
        visitor.touch
      end
    end

    def event_for_params(type, project, device, data, link, engagement_time = nil, created_at: nil)
      event = Event.new()
      event.event = type
      event.project = project
      event.device = device
      event.data = data
      event.link = link
      event.engagement_time = Event.clamp_engagement_time(engagement_time)
      event.created_at = created_at if created_at

      if device
        event.ip = device.ip
        event.remote_ip = device.remote_ip
        event.vendor_id = device.vendor
        event.platform = device.platform
        event.app_version = device.app_version
        event.build = device.build
      end

      if link
        event.path = link.path
      end

      event
    end

  end

end
