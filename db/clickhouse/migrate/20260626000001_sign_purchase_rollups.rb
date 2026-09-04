# frozen_string_literal: true

# Makes the purchase revenue rollups EXACT + SIGNED, matching PG's source of
# truth PurchaseEvent#revenue_delta / units_sold:
#   buy, refund_reversed => +usd*qty ; refund => -usd*qty ;
#   cancel => -usd*qty only when purchase_type != subscription, else 0 ;
#   cents == 0 => 0 (falls out of the arithmetic).
# units = qty only for buy/refund_reversed (PG units_sold = buy? ? qty : 0).
#
# purchase_project_daily stays ReplacingMergeTree (already keyed by transaction).
# purchase_product_daily is converted SummingMergeTree -> ReplacingMergeTree keyed
# (project_id, transaction_id, product_id, event_type) so retries dedup instead of
# double-counting. Both MVs + historical backfills use the same signing expression.
class SignPurchaseRollups < Clickhouse::Migration
  # multiIf matching PurchaseEvent#revenue_delta, shared by MV + backfill.
  SIGNED_REVENUE_SQL = <<~EXPR.strip
    multiIf(
      event_type IN ('buy', 'refund_reversed'), usd_price_cents * quantity,
      event_type = 'refund', -(usd_price_cents * quantity),
      event_type = 'cancel' AND purchase_type != 'subscription', -(usd_price_cents * quantity),
      0
    )
  EXPR

  # units_sold = quantity only for buy?-type events (buy / refund_reversed).
  SIGNED_UNITS_SQL = <<~EXPR.strip
    if(event_type IN ('buy', 'refund_reversed'), quantity, 0)
  EXPR

  def up
    rebuild_project_daily
    rebuild_product_daily
  end

  private

  def rebuild_project_daily
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
      PARTITION BY toYYYYMM(event_date)
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
          #{SIGNED_REVENUE_SQL} AS total_revenue_cents,
          #{SIGNED_UNITS_SQL} AS units,
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
          #{SIGNED_REVENUE_SQL} AS total_revenue_cents,
          #{SIGNED_UNITS_SQL} AS units,
          created_at
      FROM purchase_events FINAL
    SQL
  end

  def rebuild_product_daily
    execute "DROP TABLE IF EXISTS mv_purchase_product_daily"
    execute "DROP TABLE IF EXISTS purchase_product_daily"

    execute <<~SQL
      CREATE TABLE IF NOT EXISTS purchase_product_daily (
          project_id              UInt64,
          product_id              String,
          event_date              Date,
          event_type              LowCardinality(String),
          store_source            LowCardinality(String),
          transaction_id          String,
          total_revenue_cents     Int64 DEFAULT 0,
          units                   UInt64 DEFAULT 0,
          created_at              DateTime64(3, 'UTC'),

          INDEX idx_event_date event_date TYPE minmax GRANULARITY 4
      )
      ENGINE = ReplacingMergeTree(created_at)
      PARTITION BY toYYYYMM(event_date)
      ORDER BY (project_id, transaction_id, product_id, event_type)
      SETTINGS index_granularity = 8192
    SQL

    execute <<~SQL
      CREATE MATERIALIZED VIEW IF NOT EXISTS mv_purchase_product_daily TO purchase_product_daily AS
      SELECT
          project_id,
          product_id,
          toDate(purchase_date) AS event_date,
          event_type,
          store_source,
          transaction_id,
          #{SIGNED_REVENUE_SQL} AS total_revenue_cents,
          #{SIGNED_UNITS_SQL} AS units,
          created_at
      FROM purchase_events
    SQL

    execute <<~SQL
      INSERT INTO purchase_product_daily
      SELECT
          project_id,
          product_id,
          toDate(purchase_date) AS event_date,
          event_type,
          store_source,
          transaction_id,
          #{SIGNED_REVENUE_SQL} AS total_revenue_cents,
          #{SIGNED_UNITS_SQL} AS units,
          created_at
      FROM purchase_events FINAL
    SQL
  end
end
