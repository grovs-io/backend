# frozen_string_literal: true

class CreateProjectCountryDaily < Clickhouse::Migration
  def up
    execute <<~SQL
      CREATE TABLE IF NOT EXISTS project_country_daily (
          project_id              UInt64,
          event_date              Date,
          country                 LowCardinality(String),
          event_type              LowCardinality(String),
          platform                LowCardinality(String),
          cnt                     SimpleAggregateFunction(sum, UInt64),
          visitors_state          AggregateFunction(uniq, UInt64)
      )
      ENGINE = AggregatingMergeTree()
      PARTITION BY toYYYYMM(event_date)
      ORDER BY (project_id, event_date, country, event_type, platform)
      SETTINGS index_granularity = 8192
    SQL
  end
end
