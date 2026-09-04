# Synchronous event ingestion fallback — creates the Event record directly in the database.
#
# This job is the SECOND layer in the event ingestion fallback chain:
#   1. Redis LPUSH → BatchEventProcessorJob (primary async path)
#   2. LogEventJob (this) — if Redis LPUSH fails
#   3. Inline sync call — if Sidekiq enqueue also fails
#
# Called by: EventIngestionService.fallback_to_sidekiq (when Redis LPUSH raises)
#
# Unlike the primary path (which bulk-inserts via BatchEventProcessorJob), this job
# processes a single event synchronously through EventIngestionService.log_event_without_view_duplicates,
# which deduplicates VIEW events within a 5-second window and writes directly to the DB.
#
# See also:
#   - AddEventJob: emergency drain rake tasks (resolves links before enqueuing)
#   - ProcessNormalEventJob: async retry when event stat processing fails
#   - BatchEventProcessorJob: primary async event processor (pops from Redis)
class LogEventJob
  include Sidekiq::Job
  sidekiq_options queue: :events, retry: 5

  # Extra args default for queued-job compatibility across deploys.
  def perform(type, project_id, device_id, data, link_id, engagement_time = nil, created_at_iso = nil, # rubocop:disable Metrics/ParameterLists -- Sidekiq positional args, frozen for queued-job compatibility
              event_name = "", session_id = "", tags = [], ch_meta = nil)
    project = Project.find_by(id: project_id)
    device = Device.find_by(id: device_id)
    return unless project && device

    link = Link.find_by(id: link_id) if link_id
    # Sidekiq round-trips JSON, so keys come back as strings; resolve_ch_source keys off symbols.
    frozen = ch_meta&.symbolize_keys

    parsed_at = nil
    if created_at_iso.present?
      parsed_at = begin
        Time.parse(created_at_iso)
      rescue ArgumentError
        nil
      end
    end

    if Clickhouse.primary?
      # Sidekiq ran us, so Redis is back — re-enter the batch pipeline
      EventIngestionService.log_async(
        type, project, device, data, link, engagement_time,
        created_at: parsed_at, event_name: event_name, session_id: session_id, tags: tags,
        sidekiq_fallback: false, ch_meta: frozen
      )
      return
    end

    EventIngestionService.log_event_without_view_duplicates(
      type, project, device, data, link, engagement_time,
      created_at: parsed_at, event_name: event_name, session_id: session_id, tags: tags, ch_meta: frozen
    )
  end
end
