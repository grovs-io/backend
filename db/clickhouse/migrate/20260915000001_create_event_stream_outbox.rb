# frozen_string_literal: true

class CreateEventStreamOutbox < Clickhouse::Migration
  EVENT_COLUMNS = %w[
    event_id project_id event_type event_name screen_name device_id visitor_id link_id inviter_id campaign_id
    platform app_version build vendor_id device_model os os_version timezone language country city
    tracking_source tracking_medium tracking_campaign ads_platform link_tags sdk_identifier sdk_attributes
    session_id engagement_time properties tags sdk_generated link_visitor_id ip remote_ip path created_at ingested_at
  ].freeze

  PURCHASE_COLUMNS = %w[
    project_id event_type purchase_type product_id usd_price_cents currency quantity transaction_id
    original_transaction_id store_source device_id link_id visitor_id purchase_date created_at session_id recorded_at platform
  ].freeze

  def up
    create_allow_list
    create_events_outbox
    create_purchases_outbox
  end

  def create_allow_list
    execute <<~SQL
      CREATE TABLE IF NOT EXISTS egress_projects (
          project_id UInt64
      )
      ENGINE = MergeTree()
      ORDER BY project_id
    SQL
  end

  # outbox_at is stamped when the row reaches the outbox, so spill/DLQ replays still sort after the Bookmark.
  def create_events_outbox
    execute <<~SQL
      CREATE TABLE IF NOT EXISTS events_outbox (
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
          outbox_at       DateTime64(3, 'UTC') DEFAULT now64(3)
      )
      ENGINE = MergeTree()
      PARTITION BY toDate(outbox_at)
      ORDER BY (project_id, outbox_at, event_id)
      TTL toDateTime(outbox_at) + INTERVAL 7 DAY
      SETTINGS index_granularity = 8192
    SQL

    execute <<~SQL
      CREATE MATERIALIZED VIEW IF NOT EXISTS mv_events_outbox TO events_outbox AS
      SELECT #{EVENT_COLUMNS.join(', ')}
      FROM events
      WHERE project_id IN (SELECT project_id FROM egress_projects)
    SQL
  end

  # purchase_key carries the version, so two versions of one purchase arriving together still page apart.
  def create_purchases_outbox
    execute <<~SQL
      CREATE TABLE IF NOT EXISTS purchase_events_outbox (
          project_id              UInt64,
          event_type              LowCardinality(String),
          purchase_type           LowCardinality(String) DEFAULT '',
          product_id              String DEFAULT '',
          usd_price_cents         Int64 DEFAULT 0,
          currency                LowCardinality(String) DEFAULT '',
          quantity                UInt32 DEFAULT 1,
          transaction_id          String,
          original_transaction_id String DEFAULT '',
          store_source            LowCardinality(String) DEFAULT '',
          device_id               UInt64 DEFAULT 0,
          link_id                 UInt64 DEFAULT 0,
          visitor_id              UInt64 DEFAULT 0,
          purchase_date           DateTime64(3, 'UTC'),
          created_at              DateTime64(3, 'UTC'),
          session_id              String DEFAULT '',
          recorded_at             DateTime64(3, 'UTC') DEFAULT 0,
          platform                LowCardinality(String) DEFAULT '',
          purchase_key            String,
          outbox_at               DateTime64(3, 'UTC') DEFAULT now64(3)
      )
      ENGINE = MergeTree()
      PARTITION BY toDate(outbox_at)
      ORDER BY (project_id, outbox_at, purchase_key)
      TTL toDateTime(outbox_at) + INTERVAL 7 DAY
      SETTINGS index_granularity = 8192
    SQL

    execute <<~SQL
      CREATE MATERIALIZED VIEW IF NOT EXISTS mv_purchase_events_outbox TO purchase_events_outbox AS
      SELECT #{PURCHASE_COLUMNS.join(', ')},
             concat(transaction_id, ':', event_type, ':', toString(toUnixTimestamp64Milli(created_at))) AS purchase_key
      FROM purchase_events
      WHERE project_id IN (SELECT project_id FROM egress_projects)
    SQL
  end
end
