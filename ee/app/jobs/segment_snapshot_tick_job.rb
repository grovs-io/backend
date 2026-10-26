class SegmentSnapshotTickJob
  include Sidekiq::Job
  sidekiq_options queue: :maintenance, retry: 0

  def perform
    return unless Segments.available?

    # Staggered so the nightly run never holds the evaluation permits against dashboard users.
    Segment.active.pluck(:id).each_with_index { |id, i| SegmentSizeSnapshotJob.perform_in(i * 2, id) }
  end
end
