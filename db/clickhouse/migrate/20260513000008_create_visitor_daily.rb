# frozen_string_literal: true

class CreateVisitorDaily < Clickhouse::Migration
  def up
    execute <<~SQL
      CREATE TABLE IF NOT EXISTS visitor_daily (
          project_id              UInt64,
          visitor_id              UInt64,
          event_date              Date,
          event_type              LowCardinality(String),
          platform                LowCardinality(String),
          cnt                     SimpleAggregateFunction(sum, UInt64),
          total_engagement_time   SimpleAggregateFunction(sum, UInt64),
          inviter_id_state        SimpleAggregateFunction(max, UInt64)
      )
      ENGINE = AggregatingMergeTree()
      PARTITION BY toYYYYMM(event_date)
      ORDER BY (project_id, visitor_id, event_date, event_type, platform)
      SETTINGS index_granularity = 8192
    SQL
  end
end
