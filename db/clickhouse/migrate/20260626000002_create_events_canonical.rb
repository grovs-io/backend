# frozen_string_literal: true

# Deduped store: same columns as `events` plus an `ingested_at` version column.
# ReplacingMergeTree collapses duplicate deliveries (retries/replays) by the
# frozen `event_id`. The plain `events` table stays for the fast explorer;
# exact counts read this table with FINAL (or argMax over ingested_at).
class CreateEventsCanonical < Clickhouse::Migration
  def up
    execute <<~SQL
      CREATE TABLE IF NOT EXISTS events_canonical (
          event_id        String DEFAULT '',
          project_id      UInt64,

          event_type      LowCardinality(String),
          event_name      String DEFAULT '',
          screen_name     String DEFAULT '',

          device_id       UInt64 DEFAULT 0,
          visitor_id      UInt64 DEFAULT 0,
          link_id         UInt64 DEFAULT 0,
          inviter_id      UInt64 DEFAULT 0,
          campaign_id     UInt64 DEFAULT 0,

          platform        LowCardinality(String) DEFAULT '',
          app_version     String DEFAULT '',
          build           String DEFAULT '',
          vendor_id       String DEFAULT '',
          device_model    String DEFAULT '',
          os              LowCardinality(String) DEFAULT '',
          os_version      String DEFAULT '',
          timezone        String DEFAULT '',
          language        LowCardinality(String) DEFAULT '',

          country         LowCardinality(String) DEFAULT '',
          city            String DEFAULT '',

          tracking_source  LowCardinality(String) DEFAULT '',
          tracking_medium  LowCardinality(String) DEFAULT '',
          tracking_campaign String DEFAULT '',
          ads_platform     LowCardinality(String) DEFAULT '',
          link_tags        Array(LowCardinality(String)),

          sdk_identifier   String DEFAULT '',
          sdk_attributes   JSON,

          session_id      String DEFAULT '',

          engagement_time UInt64 DEFAULT 0,
          properties      JSON,
          tags            Array(LowCardinality(String)),

          sdk_generated    UInt8 DEFAULT 0,
          link_visitor_id  UInt64 DEFAULT 0,

          ip              String DEFAULT '',
          remote_ip       String DEFAULT '',
          path            String DEFAULT '',

          created_at      DateTime64(3, 'UTC'),
          ingested_at     DateTime64(3, 'UTC'),

          INDEX idx_visitor visitor_id TYPE minmax GRANULARITY 4,
          INDEX idx_link link_id TYPE minmax GRANULARITY 4,
          INDEX idx_event_id event_id TYPE bloom_filter(0.01) GRANULARITY 4
      )
      ENGINE = ReplacingMergeTree(ingested_at)
      PARTITION BY toYYYYMM(created_at)
      ORDER BY (project_id, toDate(created_at), event_type, event_id)
      SETTINGS index_granularity = 8192
    SQL
  end
end
