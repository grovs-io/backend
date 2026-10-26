# frozen_string_literal: true

class AddRecordedAtAndPlatformToPurchaseEvents < Clickhouse::Migration
  def up
    execute <<~SQL
      ALTER TABLE purchase_events
        ADD COLUMN IF NOT EXISTS recorded_at DateTime64(3, 'UTC') DEFAULT 0,
        ADD COLUMN IF NOT EXISTS platform LowCardinality(String) DEFAULT ''
    SQL
  end
end
