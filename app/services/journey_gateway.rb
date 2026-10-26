# Core entry point for journeys; a no-op without ee/.
module JourneyGateway
  module_function

  # After the batch is acked: a failure here must never cost the batch its ClickHouse write.
  def observe(event_rows, visitors_index)
    return unless defined?(Journeys)

    Journeys.observe(event_rows, visitors_index)
  rescue StandardError => e
    Grovs::Metrics.increment("journeys.observe_failed", tags: { error: e.class.name })
    Rails.logger.warn("journeys.observe_failed #{e.class}: #{e.message}")
  end

  def identified(visitor)
    Journeys.identified(visitor) if defined?(Journeys) && Grovs.journeys_enabled?
  end

  def merge(from:, to:)
    Journeys.merge(from: from, to: to) if defined?(Journeys)
  end
end
