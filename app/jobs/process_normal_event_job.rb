# Async retry for failed event stat processing.
#
# When an Event record has been saved to the DB but EventStatDispatchService.call_normal_event
# raises during synchronous processing, this job retries that stat dispatch asynchronously.
# This ensures stats (link daily statistics, visitor daily statistics, etc.) are eventually
# computed even if the initial attempt fails.
#
# Called by: EventIngestionService.process_event (rescue block, on any StandardError)
#
# Flow:
#   EventIngestionService.log → event.save! → process_event → EventStatDispatchService (fails)
#     → ProcessNormalEventJob.perform_async(event.id) → EventStatDispatchService (retry)
#
# See also:
#   - AddEventJob: emergency drain rake tasks (resolves links before enqueuing)
#   - LogEventJob: sync fallback when Redis LPUSH fails
#   - BatchEventProcessorJob: primary async event processor (pops from Redis)
class ProcessNormalEventJob
  include Sidekiq::Job
  sidekiq_options queue: :events, retry: 3

  def perform(event_id)
    event = Event.includes(:device).find_by(id: event_id)
    return unless event

    EventStatDispatchService.call_normal_event(event)
  rescue StandardError => e
    Rails.logger.error "Failed to process event #{event_id}: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
    raise
  end
end