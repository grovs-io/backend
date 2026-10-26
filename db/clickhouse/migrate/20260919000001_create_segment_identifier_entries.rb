# frozen_string_literal: true

class CreateSegmentIdentifierEntries < Clickhouse::Migration
  def up
    execute <<~SQL
      CREATE TABLE IF NOT EXISTS segment_identifier_entries (
          project_id  UInt64,
          segment_id  UInt64,
          generation  String,
          identifier  String
      )
      ENGINE = MergeTree
      ORDER BY (project_id, segment_id, generation, identifier)
      SETTINGS index_granularity = 8192
    SQL
  end
end
