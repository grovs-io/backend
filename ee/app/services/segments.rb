module Segments
  class Busy < StandardError; end
  class WindowExpired < StandardError; end
  class InvalidDefinition < StandardError; end
  class ResultExpired < StandardError; end
  class UploadInProgress < StandardError; end
  class InvalidList < StandardError; end

  def self.available? = Clickhouse.read_enabled? && Clickhouse.enabled?

  def self.result_for(project, segment, lane: :dashboard)
    raise ArgumentError, "segment does not belong to project" unless segment.project_id == project.id

    Results.for(project: project, definition: segment.parsed_definition, list_generation: segment.identifier_list_generation,
                segment_id: segment.id, lane: lane)
  end

  def self.visitor_filter_sql(project, segment_hashid, column: "visitor_id", effective: false)
    raise ArgumentError, "unknown column" unless SegmentFilter::COLUMNS.include?(column)

    segment = project.segments.active.find_by_hashid(segment_hashid)
    raise ActiveRecord::RecordNotFound, "segment" if segment.nil?

    manifest = result_for(project, segment)
    id_column = effective ? "eff_visitor_id" : "visitor_id"
    "#{column} IN (SELECT #{id_column} FROM segment_results WHERE #{Results.scope_sql(manifest)})"
  end

  # list_from: the saved segment whose identifier list backs a draft definition's in_list condition.
  def self.estimate(project, segment_or_definition, list_from: nil, lane: :dashboard)
    if segment_or_definition.is_a?(Segment)
      raise ArgumentError, "segment does not belong to project" if segment_or_definition.project_id != project.id

      Runner.estimate(project: project, definition: segment_or_definition.parsed_definition,
                      list_generation: segment_or_definition.identifier_list_generation, segment_id: segment_or_definition.id, lane: lane)
    elsif list_from
      raise ArgumentError, "segment does not belong to project" if list_from.project_id != project.id

      Runner.estimate(project: project, definition: segment_or_definition,
                      list_generation: list_from.identifier_list_generation, segment_id: list_from.id, lane: lane)
    else
      Runner.estimate(project: project, definition: segment_or_definition, lane: lane)
    end
  end

  def self.estimate_with_platforms(project, segment)
    raise ArgumentError, "segment does not belong to project" if segment.project_id != project.id

    Runner.estimate_with_platforms(project: project, definition: segment.parsed_definition,
                                   list_generation: segment.identifier_list_generation, segment_id: segment.id)
  end
end
