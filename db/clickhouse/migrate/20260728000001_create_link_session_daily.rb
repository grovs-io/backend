# frozen_string_literal: true

# Sum+count, not a pre-divided average. See the cutover plan.
class CreateLinkSessionDaily < Clickhouse::Migration
  def up
    execute <<~SQL
      CREATE TABLE IF NOT EXISTS link_session_daily (
          project_id       UInt64,
          link_id          UInt64,
          event_date       Date,
          platform         LowCardinality(String),
          sessions         UInt64 DEFAULT 0,
          duration_ms_sum  UInt64 DEFAULT 0
      )
      ENGINE = MergeTree()
      PARTITION BY toYYYYMM(event_date)
      ORDER BY (project_id, link_id, event_date, platform)
      SETTINGS index_granularity = 8192
    SQL
  end
end
