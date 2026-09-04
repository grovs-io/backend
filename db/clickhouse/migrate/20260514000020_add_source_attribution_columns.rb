# frozen_string_literal: true

class AddSourceAttributionColumns < Clickhouse::Migration
  def up
    execute <<~SQL
      ALTER TABLE events
        ADD COLUMN IF NOT EXISTS sdk_generated UInt8 DEFAULT 0,
        ADD COLUMN IF NOT EXISTS link_visitor_id UInt64 DEFAULT 0
    SQL

    execute <<~SQL
      ALTER TABLE session_events
        ADD COLUMN IF NOT EXISTS sdk_generated UInt8 DEFAULT 0,
        ADD COLUMN IF NOT EXISTS link_visitor_id UInt64 DEFAULT 0
    SQL

    execute <<~SQL
      ALTER TABLE session_summary
        ADD COLUMN IF NOT EXISTS sdk_generated UInt8 DEFAULT 0,
        ADD COLUMN IF NOT EXISTS link_visitor_id UInt64 DEFAULT 0
    SQL
  end
end
