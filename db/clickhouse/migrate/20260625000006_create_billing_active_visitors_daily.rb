# frozen_string_literal: true

class CreateBillingActiveVisitorsDaily < Clickhouse::Migration
  def up
    execute <<~SQL
      CREATE TABLE IF NOT EXISTS billing_active_visitors_daily (
          project_id   UInt64,
          event_date   Date,
          visitors_state AggregateFunction(uniqExact, UInt64)
      )
      ENGINE = AggregatingMergeTree()
      PARTITION BY toYYYYMM(event_date)
      ORDER BY (project_id, event_date)
      SETTINGS index_granularity = 8192
    SQL

    execute <<~SQL
      CREATE MATERIALIZED VIEW IF NOT EXISTS mv_billing_active_visitors_daily
      TO billing_active_visitors_daily AS
      SELECT
          project_id,
          toDate(created_at) AS event_date,
          uniqExactState(visitor_id) AS visitors_state
      FROM events
      WHERE visitor_id != 0
        AND event_type IN (
          'view',
          'open',
          'install',
          'reinstall',
          'time_spent',
          'reactivation',
          'app_open',
          'user_referred'
        )
      GROUP BY project_id, event_date
    SQL

    # Inline backfill is safe here because uniqExactState merges as a set:
    # overlapping rows from live MV inserts and this backfill deduplicate.
    execute <<~SQL
      INSERT INTO billing_active_visitors_daily
      SELECT
          project_id,
          toDate(created_at) AS event_date,
          uniqExactState(visitor_id) AS visitors_state
      FROM events
      WHERE visitor_id != 0
        AND event_type IN (
          'view',
          'open',
          'install',
          'reinstall',
          'time_spent',
          'reactivation',
          'app_open',
          'user_referred'
        )
      GROUP BY project_id, event_date
    SQL
  end
end
