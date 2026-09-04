# frozen_string_literal: true

class CreateSessionEvents < Clickhouse::Migration
  def up
    execute <<~SQL
      CREATE TABLE IF NOT EXISTS session_events (
          project_id      UInt64,
          session_id      String,
          visitor_id      UInt64,
          device_id       UInt64,
          event_id        String DEFAULT '',
          event_date      Date,
          event_type      LowCardinality(String),
          event_name      String DEFAULT '',
          screen_name     String DEFAULT '',
          platform        LowCardinality(String),
          app_version     String DEFAULT '',
          country         LowCardinality(String),
          device_model    String DEFAULT '',
          link_id         UInt64 DEFAULT 0,
          campaign_id     UInt64 DEFAULT 0,
          tracking_source LowCardinality(String) DEFAULT '',
          engagement_time UInt64 DEFAULT 0,
          properties      JSON,
          created_at      DateTime64(3, 'UTC'),

          INDEX idx_visitor visitor_id TYPE minmax GRANULARITY 4,
          INDEX idx_event_id event_id TYPE bloom_filter(0.01) GRANULARITY 4,
          INDEX idx_session session_id TYPE bloom_filter(0.01) GRANULARITY 4,
          INDEX idx_screen screen_name TYPE set(100) GRANULARITY 4
      )
      ENGINE = MergeTree()
      PARTITION BY toYYYYMM(event_date)
      ORDER BY (project_id, event_date, session_id, created_at)
      SETTINGS index_granularity = 8192
    SQL
  end
end
