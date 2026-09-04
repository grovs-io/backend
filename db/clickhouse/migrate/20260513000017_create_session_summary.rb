# frozen_string_literal: true

class CreateSessionSummary < Clickhouse::Migration
  def up
    execute <<~SQL
      CREATE TABLE IF NOT EXISTS session_summary (
          project_id      UInt64,
          session_id      String,
          visitor_id      UInt64,
          event_date      Date,
          platform        LowCardinality(String),
          app_version     String DEFAULT '',
          country         LowCardinality(String),
          device_model    String DEFAULT '',
          tracking_source LowCardinality(String) DEFAULT '',
          link_id         UInt64 DEFAULT 0,
          campaign_id     UInt64 DEFAULT 0,
          screen_count    UInt32 DEFAULT 0,
          event_count     UInt32 DEFAULT 0,
          duration_ms     UInt64 DEFAULT 0,
          first_screen    String DEFAULT '',
          last_screen     String DEFAULT '',
          has_conversion  UInt8 DEFAULT 0,
          revenue_usd_cents Int64 DEFAULT 0,
          started_at      DateTime64(3, 'UTC'),
          ended_at        DateTime64(3, 'UTC')
      )
      ENGINE = ReplacingMergeTree(ended_at)
      PARTITION BY toYYYYMM(event_date)
      ORDER BY (project_id, event_date, visitor_id, session_id)
      SETTINGS index_granularity = 8192
    SQL
  end
end
