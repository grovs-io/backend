# frozen_string_literal: true

# Exact daily rollups mirroring the PG stat tables (daily_project_metrics,
# link_daily_statistics, visitor_daily_statistics). These are REBUILT from the
# deduped events_canonical on a schedule by ClickhouseRollupRebuildService — NOT
# insert-triggered MVs (an MV can't subtract a duplicate it already aggregated).
# Plain MergeTree: the rebuild does an atomic REPLACE PARTITION from a fully
# recomputed staging table, so rows are never partial/duplicated and no FINAL is
# needed at read time. Partitioned toYYYYMM(event_date) so rebuilds are
# partition-scoped, never O(all-history).
#
# The project rollup mirrors ONLY the directly-countable columns that exist in PG
# daily_project_metrics (views/opens/installs/reinstalls/app_opens). That PG table
# has no time_spent/reactivations/user_referred column, and its derived/attribution
# columns (new_users, organic_users, …) and purchase columns (revenue, …) are NOT
# event-countable — they arrive in Phase 5 / the purchase pipeline, not here. The
# link and visitor rollups DO carry the full event-countable set (their PG tables
# have those columns); none of the rollups carry revenue.
class CreateCanonicalMetricsRollups < Clickhouse::Migration
  def up
    execute <<~SQL
      CREATE TABLE IF NOT EXISTS project_metrics_daily (
          project_id      UInt64,
          event_date      Date,
          platform        LowCardinality(String),
          views           UInt64 DEFAULT 0,
          opens           UInt64 DEFAULT 0,
          installs        UInt64 DEFAULT 0,
          reinstalls      UInt64 DEFAULT 0,
          app_opens       UInt64 DEFAULT 0,
          unique_visitors UInt64 DEFAULT 0,
          unique_devices  UInt64 DEFAULT 0
      )
      ENGINE = MergeTree()
      PARTITION BY toYYYYMM(event_date)
      ORDER BY (project_id, event_date, platform)
      SETTINGS index_granularity = 8192
    SQL

    execute <<~SQL
      CREATE TABLE IF NOT EXISTS link_metrics_daily (
          project_id      UInt64,
          link_id         UInt64,
          event_date      Date,
          platform        LowCardinality(String),
          views           UInt64 DEFAULT 0,
          opens           UInt64 DEFAULT 0,
          installs        UInt64 DEFAULT 0,
          reinstalls      UInt64 DEFAULT 0,
          time_spent      UInt64 DEFAULT 0,
          reactivations   UInt64 DEFAULT 0,
          app_opens       UInt64 DEFAULT 0,
          user_referred   UInt64 DEFAULT 0
      )
      ENGINE = MergeTree()
      PARTITION BY toYYYYMM(event_date)
      ORDER BY (project_id, link_id, event_date, platform)
      SETTINGS index_granularity = 8192
    SQL

    execute <<~SQL
      CREATE TABLE IF NOT EXISTS visitor_metrics_daily (
          project_id      UInt64,
          visitor_id      UInt64,
          event_date      Date,
          platform        LowCardinality(String),
          views           UInt64 DEFAULT 0,
          opens           UInt64 DEFAULT 0,
          installs        UInt64 DEFAULT 0,
          reinstalls      UInt64 DEFAULT 0,
          time_spent      UInt64 DEFAULT 0,
          reactivations   UInt64 DEFAULT 0,
          app_opens       UInt64 DEFAULT 0,
          user_referred   UInt64 DEFAULT 0,
          inviter_id      UInt64 DEFAULT 0
      )
      ENGINE = MergeTree()
      PARTITION BY toYYYYMM(event_date)
      ORDER BY (project_id, visitor_id, event_date, platform)
      SETTINGS index_granularity = 8192
    SQL
  end
end
