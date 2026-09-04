# frozen_string_literal: true

class RebuildPurchaseProjectDailyAsReplacingFacts < Clickhouse::Migration
  def up
    execute "DROP TABLE IF EXISTS mv_purchase_project_daily"
    execute "DROP TABLE IF EXISTS purchase_project_daily"

    execute <<~SQL
      CREATE TABLE IF NOT EXISTS purchase_project_daily (
          project_id              UInt64,
          event_date              Date,
          event_type              LowCardinality(String),
          store_source            LowCardinality(String),
          transaction_id          String,
          visitor_id              UInt64 DEFAULT 0,
          total_revenue_cents     Int64 DEFAULT 0,
          units                   UInt64 DEFAULT 0,
          created_at              DateTime64(3, 'UTC'),

          INDEX idx_event_date event_date TYPE minmax GRANULARITY 4
      )
      ENGINE = ReplacingMergeTree(created_at)
      ORDER BY (project_id, transaction_id, event_type)
      SETTINGS index_granularity = 8192
    SQL

    execute <<~SQL
      CREATE MATERIALIZED VIEW IF NOT EXISTS mv_purchase_project_daily TO purchase_project_daily AS
      SELECT
          project_id,
          toDate(purchase_date) AS event_date,
          event_type,
          store_source,
          transaction_id,
          visitor_id,
          usd_price_cents * quantity AS total_revenue_cents,
          quantity AS units,
          created_at
      FROM purchase_events
    SQL

    execute <<~SQL
      INSERT INTO purchase_project_daily
      SELECT
          project_id,
          toDate(purchase_date) AS event_date,
          event_type,
          store_source,
          transaction_id,
          visitor_id,
          usd_price_cents * quantity AS total_revenue_cents,
          quantity AS units,
          created_at
      FROM purchase_events FINAL
    SQL
  end
end
