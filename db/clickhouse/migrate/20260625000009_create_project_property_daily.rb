# frozen_string_literal: true

class CreateProjectPropertyDaily < Clickhouse::Migration
  def up
    # No inline backfill here: create-MV-plus-INSERT migrations can double-count
    # live inserts in aggregate tables. Backfill this rollup as a controlled job.
    execute <<~SQL
      CREATE TABLE IF NOT EXISTS project_property_daily (
          project_id      UInt64,
          event_date      Date,
          property_key    LowCardinality(String),
          property_value  String,
          event_type      LowCardinality(String),
          platform        LowCardinality(String),
          cnt             SimpleAggregateFunction(sum, UInt64),
          visitors_state  AggregateFunction(uniq, UInt64)
      )
      ENGINE = AggregatingMergeTree()
      PARTITION BY toYYYYMM(event_date)
      ORDER BY (project_id, event_date, property_key, property_value, event_type, platform)
      SETTINGS index_granularity = 8192
    SQL

    execute <<~SQL
      CREATE MATERIALIZED VIEW IF NOT EXISTS mv_project_property_daily
      TO project_property_daily AS
      SELECT
          project_id,
          toDate(created_at) AS event_date,
          property_key,
          property_value,
          event_type,
          platform,
          count() AS cnt,
          uniqState(visitor_id) AS visitors_state
      FROM
      (
          SELECT
              project_id,
              created_at,
              event_type,
              platform,
              visitor_id,
              arrayJoin([
                tuple('plan', JSONExtractString(properties, 'plan')),
                tuple('tier', JSONExtractString(properties, 'tier'))
              ]) AS property_tuple,
              property_tuple.1 AS property_key,
              property_tuple.2 AS property_value
          FROM events
      )
      WHERE property_value != ''
      GROUP BY project_id, event_date, property_key, property_value, event_type, platform
    SQL
  end
end
