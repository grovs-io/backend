# frozen_string_literal: true

class AddSessionIdToPurchaseEvents < Clickhouse::Migration
  def up
    execute <<~SQL
      ALTER TABLE purchase_events
        ADD COLUMN IF NOT EXISTS session_id String DEFAULT ''
    SQL
  end
end
