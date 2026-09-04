# frozen_string_literal: true

# Link filter attributes mirrored from Postgres: docs/plans/2026-08-01-link-dimensions.md
class CreateLinkDimensions < Clickhouse::Migration
  def up
    execute <<~SQL
      CREATE TABLE IF NOT EXISTS link_dimensions (
          project_id      UInt64,
          link_id         UInt64,
          active          UInt8   DEFAULT 1,
          sdk_generated   UInt8   DEFAULT 0,
          campaign_id     UInt64  DEFAULT 0,
          ads_platform    LowCardinality(String) DEFAULT '',
          name            String  DEFAULT '',
          title           String  DEFAULT '',
          subtitle        String  DEFAULT '',
          path            String  DEFAULT '',
          tags            Array(String) DEFAULT [],
          deleted         UInt8   DEFAULT 0,
          version         DateTime64(6) DEFAULT now64(6)
      )
      ENGINE = ReplacingMergeTree(version)
      ORDER BY (project_id, link_id)
      SETTINGS index_granularity = 8192
    SQL
  end
end
