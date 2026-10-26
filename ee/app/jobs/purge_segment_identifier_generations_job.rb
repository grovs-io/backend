class PurgeSegmentIdentifierGenerationsJob
  include Sidekiq::Job
  sidekiq_options queue: :maintenance, retry: 3

  RETRY_DELAY = 10.minutes

  def perform(segment_id)
    segment = Segment.find_by(id: segment_id)
    return if segment.nil? || !Clickhouse.enabled?

    Segments::IdentifierList.with_lock(segment_id) { delete_superseded(segment) }
  rescue Segments::UploadInProgress
    self.class.perform_in(RETRY_DELAY, segment_id)
  end

  private

  def delete_superseded(segment)
    keep = ([segment.reload.identifier_list_generation] + generations_in_use(segment)).compact_blank.uniq
    condition = "project_id = #{Integer(segment.project_id)} AND segment_id = #{Integer(segment.id)}"
    if keep.any?
      raise ArgumentError, "bad generation" unless keep.all? { |generation| generation.match?(/\A\h{32}\z/) }

      condition += " AND generation NOT IN (#{keep.map { |generation| "'#{generation}'" }.join(', ')})"
    end
    Clickhouse.with { |conn| conn.execute("ALTER TABLE segment_identifier_entries DELETE WHERE #{condition}") }
  end

  # Scheduled pushes read their list when they freeze; journeys keep the one they launched with until finished.
  def generations_in_use(segment)
    in_app = InAppCampaign.active.where(segment_id: segment.id).distinct.pluck(:segment_list_generation)
    push = PushCampaign.where(segment_id: segment.id, status: %w[scheduled evaluating]).distinct.pluck(:segment_list_generation)
    journeys = Journey.where(project_id: segment.project_id, status: Journey::STATUSES - ["draft"], finished_at: nil).pluck(:segment_keys)
                      .flat_map(&:values).select { |spec| spec["segment_id"] == segment.id }.pluck("list_generation")
    in_app + push + journeys
  end
end
