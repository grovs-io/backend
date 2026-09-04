# frozen_string_literal: true

class CreateProjectSourceDaily < Clickhouse::Migration
  # Frozen literal — migrations stay self-contained (no app-code dependency).
  # Must remain equivalent to Analytics::SourceTaxonomy.expr; the
  # source_taxonomy drift test enforces that the deployed MV matches it.
  SOURCE_TYPE_EXPR = <<~SQL.squish
    multiIf(
      campaign_id > 0, 'campaigns',
      sdk_generated = 1 AND link_visitor_id > 0, 'referrals',
      sdk_generated = 1 AND link_visitor_id = 0, 'api_links',
      link_id > 0, 'links',
      'organic'
    )
  SQL

  def up
    # No inline backfill here: create-MV-plus-INSERT migrations can double-count
    # live inserts in aggregate tables. Backfill this rollup as a controlled job.
    execute <<~SQL
      CREATE TABLE IF NOT EXISTS project_source_daily (
          project_id      UInt64,
          event_date      Date,
          source          LowCardinality(String),
          platform        LowCardinality(String),
          cnt             SimpleAggregateFunction(sum, UInt64),
          visitors_state  AggregateFunction(uniq, UInt64)
      )
      ENGINE = AggregatingMergeTree()
      PARTITION BY toYYYYMM(event_date)
      ORDER BY (project_id, event_date, source, platform)
      SETTINGS index_granularity = 8192
    SQL

    execute <<~SQL
      CREATE MATERIALIZED VIEW IF NOT EXISTS mv_project_source_daily
      TO project_source_daily AS
      SELECT
          project_id,
          toDate(created_at) AS event_date,
          #{SOURCE_TYPE_EXPR} AS source,
          platform,
          count() AS cnt,
          uniqState(visitor_id) AS visitors_state
      FROM events
      GROUP BY project_id, event_date, source, platform
    SQL
  end
end
