# frozen_string_literal: true

class CreateProjectVersionDaily < Clickhouse::Migration
  def up
    # No inline backfill here: create-MV-plus-INSERT migrations can double-count
    # live inserts in aggregate tables. Backfill this rollup as a controlled job.
    execute <<~SQL
      CREATE TABLE IF NOT EXISTS project_version_daily (
          project_id      UInt64,
          event_date      Date,
          app_version     String,
          platform        LowCardinality(String),
          cnt             SimpleAggregateFunction(sum, UInt64),
          visitors_state  AggregateFunction(uniq, UInt64),
          first_seen      SimpleAggregateFunction(min, DateTime64(3, 'UTC'))
      )
      ENGINE = AggregatingMergeTree()
      PARTITION BY toYYYYMM(event_date)
      ORDER BY (project_id, event_date, app_version, platform)
      SETTINGS index_granularity = 8192
    SQL

    execute <<~SQL
      CREATE MATERIALIZED VIEW IF NOT EXISTS mv_project_version_daily
      TO project_version_daily AS
      SELECT
          project_id,
          toDate(created_at) AS event_date,
          app_version,
          platform,
          count() AS cnt,
          uniqState(visitor_id) AS visitors_state,
          min(created_at) AS first_seen
      FROM events
      GROUP BY project_id, event_date, app_version, platform
    SQL
  end
end
