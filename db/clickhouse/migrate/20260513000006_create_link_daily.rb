# frozen_string_literal: true

class CreateLinkDaily < Clickhouse::Migration
  def up
    execute <<~SQL
      CREATE TABLE IF NOT EXISTS link_daily (
          project_id              UInt64,
          link_id                 UInt64,
          campaign_id             UInt64 DEFAULT 0,
          event_date              Date,
          event_type              LowCardinality(String),
          platform                LowCardinality(String),
          cnt                     UInt64 DEFAULT 0,
          total_engagement_time   UInt64 DEFAULT 0
      )
      ENGINE = SummingMergeTree((cnt, total_engagement_time))
      PARTITION BY toYYYYMM(event_date)
      ORDER BY (project_id, link_id, event_date, event_type, platform, campaign_id)
      SETTINGS index_granularity = 8192
    SQL
  end
end
