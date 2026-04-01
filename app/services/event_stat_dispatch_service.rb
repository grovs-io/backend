class EventStatDispatchService
  def self.call_normal_event(event)
    if event.processed
      return
    end

    metric = Grovs::Events::MAPPING[event.event]
    return nil unless metric

    value = 1
    if event.event == Grovs::Events::TIME_SPENT
      value = event.engagement_time
    end

    if event.link_id
      LinkDailyStatService.increment_link_event(
        event_type: metric,
        project_id: event.project_id,
        link_id: event.link_id,
        platform: event.device&.platform_for_metrics || event.platform_for_metrics,
        event_date: event.created_at,
        value: value
      )
    end

    visitor = event.device&.visitor_for_project_id(event.project_id)
    if visitor
      VisitorDailyStatService.increment_visitor_event(
        visitor: visitor,
        event_type: metric,
        platform: event.device&.platform_for_metrics || event.platform_for_metrics,
        project_id: event.project_id,
        event_date: event.created_at,
        value: value
      )
    end

    event.processed = true
    event.save!
  end

  def self.call_normal_event_bulk(event)
    device = event.device
    return nil unless device

    visitor = device.visitor_for_project_id(event.project_id)
    return nil unless visitor

    metric = Grovs::Events::MAPPING[event.event]
    return nil unless metric

    value = metric == :time_spent ? event.engagement_time.to_i : 1

    visitor_stats = {
      project_id: event.project_id,
      visitor_id: visitor.id,
      invited_by_id: visitor.inviter_id,
      platform: event.device&.platform_for_metrics || event.platform_for_metrics,
      event_date: event.created_at.to_date,
      metrics: { metric => value }
    }

    link_stats = nil
    if event.link
      link_stats = {
        project_id: event.project_id,
        link_id: event.link.id,
        event_date: event.created_at.to_date,
        platform: event.device&.platform_for_metrics || event.platform_for_metrics,
        metrics: { metric => value }
      }
    end

    {
      visitor_updates: {
        stats: visitor_stats
      },
      link_updates: link_stats
    }
  end

  def self.bulk_process_updates(updates_batch)
    return if updates_batch.empty?

    visitor_stats = []
    link_stats = []

    updates_batch.each do |update|
      if update[:visitor_updates] && update[:visitor_updates][:stats]
        visitor_stats << update[:visitor_updates][:stats]
      end
      link_stats << update[:link_updates] if update[:link_updates]
    end

    VisitorDailyStatService.bulk_upsert_visitor_stats(visitor_stats) unless visitor_stats.empty?
    LinkDailyStatService.bulk_upsert_link_stats(link_stats) unless link_stats.empty?
  end
end
