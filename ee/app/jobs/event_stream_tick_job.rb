class EventStreamTickJob
  include Sidekiq::Job
  sidekiq_options queue: :maintenance, retry: 0

  # Outlives a queued-then-running job; a killed job frees its destination when this expires.
  ENQUEUED_TTL = 300

  def self.enqueued_key(destination_id) = "event_stream:enqueued:#{destination_id}"

  def perform
    return unless Grovs.event_stream_enabled?

    now = Time.current
    EventDestination.enabled.find_each do |destination|
      next unless destination.due?(now)
      next unless destination.project.instance.event_stream_enabled?
      # One outstanding job per destination, or a busy worker pool grows an unbounded backlog.
      marker = SecureRandom.hex(8)
      next unless REDIS.with { |c| c.set(self.class.enqueued_key(destination.id), marker, nx: true, ex: ENQUEUED_TTL) }

      DeliverEventDestinationJob.perform_async(destination.id, marker)
    end
  end
end
