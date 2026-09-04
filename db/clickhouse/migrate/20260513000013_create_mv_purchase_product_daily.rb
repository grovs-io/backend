# frozen_string_literal: true

class CreateMvPurchaseProductDaily < Clickhouse::Migration
  def up
    execute <<~SQL
      CREATE MATERIALIZED VIEW IF NOT EXISTS mv_purchase_product_daily TO purchase_product_daily AS
      SELECT
          project_id,
          product_id,
          toDate(purchase_date) AS event_date,
          event_type,
          store_source,
          sum(usd_price_cents) AS total_revenue_cents,
          count()              AS units
      FROM purchase_events
      GROUP BY project_id, product_id, event_date, event_type, store_source
    SQL
  end
end
