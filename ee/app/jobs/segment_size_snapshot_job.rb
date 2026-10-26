class SegmentSizeSnapshotJob
  include Sidekiq::Job
  sidekiq_options queue: :maintenance, retry: 0

  MAX_BUSY_RETRIES = 3
  SKIPPABLE = [Segments::InvalidDefinition, Segments::WindowExpired,
               Analytics::QueryTooHeavy, Clickhouse::Unavailable, Clickhouse::Stale].freeze

  def perform(segment_id, attempt = 0)
    segment = Segment.active.find_by(id: segment_id)
    return if segment.nil?

    size = Segments.estimate(segment.project, segment)
    SegmentSizeSnapshot.upsert({ segment_id: segment.id, date: Date.current, definition_hash: segment.definition_hash,
                                 persons: size[:persons], devices: size[:devices], incomplete: size[:incomplete] },
                               unique_by: %i[segment_id date])
  rescue Segments::Busy
    self.class.perform_in(rand(2..10).minutes, segment_id, attempt + 1) if attempt < MAX_BUSY_RETRIES
  rescue *SKIPPABLE => e
    Rails.logger.info("segments.snapshot.skipped segment=#{segment_id} reason=#{e.class}")
  end
end
