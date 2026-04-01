# Resolves a link (by URL or path) and enqueues an event into the async Redis pipeline.
#
# This job is NOT part of the normal request flow. It is used exclusively by
# emergency drain rake tasks (drain_events_queue, emergency_drain) that replay
# raw event data which may contain unresolved link references.
#
# Normal flow (for reference):
#   SDK request → EventIngestionService.log_async → Redis LPUSH → BatchEventProcessorJob
#
# This job's flow:
#   Rake drain task → AddEventJob → resolve link → EventIngestionService.log_async → Redis LPUSH
#
# See also:
#   - LogEventJob: sync fallback when Redis LPUSH fails
#   - ProcessNormalEventJob: async retry when event stat processing fails
#   - BatchEventProcessorJob: primary async event processor (pops from Redis)
class AddEventJob
  include Sidekiq::Job
  sidekiq_options queue: :events, retry: 1

  def perform(event_name, project_id, device_id, link_param, optional_path_param, created_at, engagement_time)
    project = Project.find(project_id)
    device = Device.find(device_id)

    if !project || !device
      Rails.logger.error("Project or Device not found for event: #{event_name}")
      return
    end

    link_to_log = nil
    if link_param.present?
      link = LinksService.link_for_url(link_param, project)
      link_to_log = link if link
    end

    if optional_path_param.present?
      link = LinksService.link_for_project_and_path(project, optional_path_param)
      link_to_log = link if link
    end

    parsed_created_at = if created_at.present?
                          begin
                            Time.parse(created_at)
                          rescue ArgumentError
                            nil
                          end
                        end
    EventIngestionService.log_async(
      event_name, project, device, nil, link_to_log, engagement_time,
      created_at: parsed_created_at
    )
  end
end
