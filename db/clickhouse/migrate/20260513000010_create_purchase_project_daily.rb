# frozen_string_literal: true

class CreatePurchaseProjectDaily < Clickhouse::Migration
  def up
    execute <<~SQL
      CREATE TABLE IF NOT EXISTS purchase_project_daily (
          project_id              UInt64,
          event_date              Date,
          event_type              LowCardinality(String),
          store_source            LowCardinality(String),
          total_revenue_cents     SimpleAggregateFunction(sum, Int64),
          units                   SimpleAggregateFunction(sum, UInt64),
          paying_visitors_state   AggregateFunction(uniq, UInt64)
      )
      ENGINE = AggregatingMergeTree()
      PARTITION BY toYYYYMM(event_date)
      ORDER BY (project_id, event_date, event_type, store_source)
      SETTINGS index_granularity = 8192
    SQL
  end
end
