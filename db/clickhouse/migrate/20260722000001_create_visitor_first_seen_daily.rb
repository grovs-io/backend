# frozen_string_literal: true

# Per (project, platform, visitor) first-seen + first-install mins — the platform-grained
# source for new_users / first_time_visitors (PG classifies per platform; visitor_acquisition
# has no platform grain). Platform normalized like Device#platform_for_metrics; install min
# counts 'install' only. event_month partitions only; reader min-merges across partitions.
# Rebuild-only (no MV), from events FINAL + identity map. Backfill history after deploy:
# RANGE=<first>-<now> ROLLUP=first_seen rake clickhouse:rebuild_rollups_range
class CreateVisitorFirstSeenDaily < Clickhouse::Migration
  def up
    execute <<~SQL
      CREATE TABLE IF NOT EXISTS visitor_first_seen_daily (
          project_id          UInt64,
          platform            LowCardinality(String),
          visitor_id          UInt64,
          event_month         Date,
          first_seen_state    AggregateFunction(min, DateTime64(3, 'UTC')),
          install_seen_state  AggregateFunction(minIf, DateTime64(3, 'UTC'), UInt8)
      )
      ENGINE = AggregatingMergeTree()
      PARTITION BY toYYYYMM(event_month)
      ORDER BY (project_id, platform, visitor_id)
      SETTINGS index_granularity = 8192
    SQL
  end
end
