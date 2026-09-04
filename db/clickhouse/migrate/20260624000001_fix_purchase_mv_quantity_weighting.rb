# frozen_string_literal: true

# Purchase rollup MVs summed usd_price_cents (a UNIT price) and count()-ed rows,
# ignoring quantity — under-reporting GROSS revenue and units for quantity>1
# purchases (Google one-time, refunds, bundles). usd_price_cents is a unit price
# across every integration (Apple/Google/SDK) and nothing pre-multiplies it, so
# multiply by quantity to match PG's revenue_delta (= usd_price_cents x quantity)
# and units_sold (= quantity).
#
# Forward-only: MVs are insert-time triggers, so this corrects rows ingested
# AFTER the migration. Dropping the MV leaves its TO target table intact;
# already-aggregated historical rows would need a separate backfill.
class FixPurchaseMvQuantityWeighting < Clickhouse::Migration
  def up
    execute "DROP TABLE IF EXISTS mv_purchase_project_daily"
    execute <<~SQL
      CREATE MATERIALIZED VIEW IF NOT EXISTS mv_purchase_project_daily TO purchase_project_daily AS
      SELECT
          project_id,
          toDate(purchase_date) AS event_date,
          event_type,
          store_source,
          sum(usd_price_cents * quantity) AS total_revenue_cents,
          sum(quantity)                   AS units,
          uniqState(visitor_id)           AS paying_visitors_state
      FROM purchase_events
      GROUP BY project_id, event_date, event_type, store_source
    SQL

    execute "DROP TABLE IF EXISTS mv_purchase_product_daily"
    execute <<~SQL
      CREATE MATERIALIZED VIEW IF NOT EXISTS mv_purchase_product_daily TO purchase_product_daily AS
      SELECT
          project_id,
          product_id,
          toDate(purchase_date) AS event_date,
          event_type,
          store_source,
          sum(usd_price_cents * quantity) AS total_revenue_cents,
          sum(quantity)                   AS units
      FROM purchase_events
      GROUP BY project_id, product_id, event_date, event_type, store_source
    SQL
  end
end
