class DeliverEventDestinationJob
  include Sidekiq::Job
  include SingleFlightJob
  # No Sidekiq retry: the Bookmark is the retry.
  sidekiq_options queue: :egress, retry: 0

  LOOP_SECONDS = 55
  # The loop plus one in-flight request (webhook TOTAL_TIMEOUT) that started just before the deadline.
  LOCK_TTL = 120

  def perform(destination_id, marker = nil)
    destination = EventDestination.find_by(id: destination_id)
    return unless destination

    single_flight!(key: "event_destination:#{destination.id}", ttl: LOCK_TTL) do
      # A job queued before a failure must still honor the backoff that failure recorded.
      next unless destination.reload.due?(Time.current)

      deadline = Time.current + LOOP_SECONDS
      loop do
        outcome = EventStream::Deliverer.new(destination.reload, deadline: deadline).run_once
        # Only a destination with more to send keeps a worker; an idle one waits for the next tick.
        break unless outcome == :delivered
        break if Time.current >= deadline
      end
    end
  ensure
    release_marker(destination_id, marker)
  end

  private

  # Compare-and-delete: an expired marker may already belong to a newer job for this destination.
  def release_marker(destination_id, marker)
    return if marker.nil?

    REDIS.with { |c| c.eval(RELEASE_LUA, keys: [EventStreamTickJob.enqueued_key(destination_id)], argv: [marker]) }
  rescue Redis::BaseError => e
    Rails.logger.warn(message: "event_stream_marker_release_failed", destination_id: destination_id, error: e.message)
  end
end
