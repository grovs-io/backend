# frozen_string_literal: true

# Durable PG fallback for CH-primary mode; stores wire-ready CH rows for replay.
module ClickhouseSpillRepository
  def self.store(prepared_rows)
    return if prepared_rows.empty?

    now = Time.current
    records = prepared_rows.map do |row|
      {
        event_id: row[:event_id],
        ch_row: row,
        project_id: row[:project_id],
        event_created_at: parse_time(row[:created_at]) || now,
        spilled_at: now
      }
    end
    result = ClickhouseEventSpill.insert_all(records, unique_by: :index_clickhouse_event_spills_on_event_id)
    Grovs::Metrics.increment("clickhouse.spill.stored", by: result.length) if result.length.positive?
  end

  def self.parse_time(value)
    Time.zone.parse(value.to_s)
  rescue ArgumentError, TypeError
    nil
  end
  private_class_method :parse_time
end
