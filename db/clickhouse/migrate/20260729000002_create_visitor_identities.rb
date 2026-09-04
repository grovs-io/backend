# frozen_string_literal: true

class CreateVisitorIdentities < Clickhouse::Migration
  def up
    execute <<~SQL
      CREATE TABLE IF NOT EXISTS visitor_identities (
          project_id     UInt64,
          visitor_id     UInt64,
          sdk_identifier String DEFAULT '',
          uuid           String DEFAULT '',
          synced_at      DateTime64(9, 'UTC')
      )
      ENGINE = MergeTree
      ORDER BY (project_id, synced_at, visitor_id)
      SETTINGS index_granularity = 8192
    SQL
  end
end
