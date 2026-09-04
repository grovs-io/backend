# frozen_string_literal: true

class CreatePurchaseEvents < Clickhouse::Migration
  def up
    execute <<~SQL
      CREATE TABLE IF NOT EXISTS purchase_events (
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
          created_at              DateTime64(3, 'UTC')
      )
      ENGINE = ReplacingMergeTree(created_at)
      PARTITION BY toYYYYMM(created_at)
      ORDER BY (project_id, transaction_id, event_type)
      SETTINGS index_granularity = 8192
    SQL
  end
end
