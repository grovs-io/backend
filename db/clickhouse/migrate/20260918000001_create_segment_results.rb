# frozen_string_literal: true

class CreateSegmentResults < Clickhouse::Migration
  def up
    execute <<~SQL
      CREATE TABLE IF NOT EXISTS segment_results (
          project_id     UInt64,
          result_id      String,
          visitor_id     UInt64,
          eff_visitor_id UInt64,
          person_key     String,
          created_at     DateTime64(3, 'UTC') DEFAULT now64(3)
      )
      ENGINE = MergeTree
      ORDER BY (project_id, result_id, visitor_id)
      TTL toDateTime(created_at) + INTERVAL 3 HOUR
      SETTINGS index_granularity = 8192
    SQL
  end
end
