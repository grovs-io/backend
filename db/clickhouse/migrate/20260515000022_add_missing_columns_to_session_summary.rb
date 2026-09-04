# frozen_string_literal: true

class AddMissingColumnsToSessionSummary < Clickhouse::Migration
  def up
    execute <<~SQL
      ALTER TABLE session_summary
        ADD COLUMN IF NOT EXISTS city String DEFAULT '',
        ADD COLUMN IF NOT EXISTS os LowCardinality(String) DEFAULT '',
        ADD COLUMN IF NOT EXISTS os_version String DEFAULT '',
        ADD COLUMN IF NOT EXISTS tracking_medium LowCardinality(String) DEFAULT '',
        ADD COLUMN IF NOT EXISTS tracking_campaign String DEFAULT '',
        ADD COLUMN IF NOT EXISTS ads_platform LowCardinality(String) DEFAULT '',
        ADD COLUMN IF NOT EXISTS sdk_identifier String DEFAULT ''
    SQL
  end
end
