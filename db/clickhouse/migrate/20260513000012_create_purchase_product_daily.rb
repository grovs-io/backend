# frozen_string_literal: true

class CreatePurchaseProductDaily < Clickhouse::Migration
  def up
    execute <<~SQL
      CREATE TABLE IF NOT EXISTS purchase_product_daily (
          project_id              UInt64,
          product_id              String,
          event_date              Date,
          event_type              LowCardinality(String),
          store_source            LowCardinality(String),
          total_revenue_cents     Int64 DEFAULT 0,
          units                   UInt64 DEFAULT 0
      )
      ENGINE = SummingMergeTree((total_revenue_cents, units))
      PARTITION BY toYYYYMM(event_date)
      ORDER BY (project_id, product_id, event_date, event_type, store_source)
      SETTINGS index_granularity = 8192
    SQL
  end
end
