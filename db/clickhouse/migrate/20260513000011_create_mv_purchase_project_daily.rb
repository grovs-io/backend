# frozen_string_literal: true

class CreateMvPurchaseProjectDaily < Clickhouse::Migration
  def up
    execute <<~SQL
      CREATE MATERIALIZED VIEW IF NOT EXISTS mv_purchase_project_daily TO purchase_project_daily AS
      SELECT
          project_id,
          toDate(purchase_date) AS event_date,
          event_type,
          store_source,
          sum(usd_price_cents) AS total_revenue_cents,
          count()              AS units,
          uniqState(visitor_id) AS paying_visitors_state
      FROM purchase_events
      GROUP BY project_id, event_date, event_type, store_source
    SQL
  end
end
