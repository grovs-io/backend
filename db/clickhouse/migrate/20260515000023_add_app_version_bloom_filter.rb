# frozen_string_literal: true

class AddAppVersionBloomFilter < Clickhouse::Migration
  def up
    execute <<~SQL
      ALTER TABLE events ADD INDEX IF NOT EXISTS idx_app_version app_version TYPE bloom_filter GRANULARITY 4
    SQL
    execute <<~SQL
      ALTER TABLE session_events ADD INDEX IF NOT EXISTS idx_app_version app_version TYPE bloom_filter GRANULARITY 4
    SQL
  end
end
