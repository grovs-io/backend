# Core entry point for filtering analytics by an enterprise segment; a no-op without ee/.
module SegmentFilter
  NotFound = Class.new(StandardError)
  Busy = Class.new(StandardError)
  Invalid = Class.new(StandardError)
  COLUMNS = %w[visitor_id up.visitor_id].freeze

  module_function

  def clause(project:, segment_id:, column: "visitor_id", effective: false)
    raise ArgumentError, "unknown column" unless COLUMNS.include?(column)
    return nil if segment_id.blank? || !defined?(Segments)

    Segments.visitor_filter_sql(project, segment_id.to_s, column: column, effective: effective)
  rescue ActiveRecord::RecordNotFound
    raise NotFound, "segment not found"
  rescue StandardError => e
    raise translate(e)
  end

  def translate(error)
    return error unless defined?(Segments)
    return Busy.new(error.message) if error.is_a?(Segments::Busy)
    return Invalid.new(error.message) if error.is_a?(Segments::InvalidDefinition) || error.is_a?(Segments::WindowExpired)

    error
  end
end
