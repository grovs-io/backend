# frozen_string_literal: true

class CreateEvents < Clickhouse::Migration
  def up
    execute <<~SQL
      CREATE TABLE IF NOT EXISTS events (
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

          ip              String DEFAULT '',
          remote_ip       String DEFAULT '',
          path            String DEFAULT '',

          created_at      DateTime64(3, 'UTC'),

          INDEX idx_visitor visitor_id TYPE minmax GRANULARITY 4,
          INDEX idx_link link_id TYPE minmax GRANULARITY 4,
          INDEX idx_device device_id TYPE minmax GRANULARITY 4,
          INDEX idx_inviter inviter_id TYPE minmax GRANULARITY 4,
          INDEX idx_country country TYPE set(200) GRANULARITY 4,
          INDEX idx_sdk_id sdk_identifier TYPE bloom_filter(0.01) GRANULARITY 4,
          INDEX idx_event_type event_type TYPE set(20) GRANULARITY 4,
          INDEX idx_event_name event_name TYPE bloom_filter(0.01) GRANULARITY 4,
          INDEX idx_event_id event_id TYPE bloom_filter(0.01) GRANULARITY 4,
          INDEX idx_screen_name screen_name TYPE bloom_filter(0.01) GRANULARITY 4,

          PROJECTION p_recent_events (
              SELECT * ORDER BY project_id, created_at
          )
      )
      ENGINE = MergeTree()
      PARTITION BY toYYYYMM(created_at)
      ORDER BY (project_id, toDate(created_at), visitor_id, created_at)
      SETTINGS index_granularity = 8192
    SQL
  end
end
