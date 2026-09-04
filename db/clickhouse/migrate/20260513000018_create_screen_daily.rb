# frozen_string_literal: true

class CreateScreenDaily < Clickhouse::Migration
  def up
    execute <<~SQL
      CREATE TABLE IF NOT EXISTS screen_daily (
          project_id      UInt64,
          screen_name     String,
          event_date      Date,
          platform        LowCardinality(String),
          visitors_state  AggregateFunction(uniq, UInt64),
          total_views     SimpleAggregateFunction(sum, UInt64),
          total_time_ms   SimpleAggregateFunction(sum, UInt64)
      )
      ENGINE = AggregatingMergeTree()
      PARTITION BY toYYYYMM(event_date)
      ORDER BY (project_id, screen_name, event_date, platform)
      SETTINGS index_granularity = 8192
    SQL
  end
end
