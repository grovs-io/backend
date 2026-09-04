# frozen_string_literal: true

# The served average excludes bounces (0ms, single-event); the totals above stay so
# reversing that decision is a read change rather than a full historical rebuild.
class AddEngagedColumnsToLinkSessionDaily < Clickhouse::Migration
  def up
    execute <<~SQL
      ALTER TABLE link_session_daily
        ADD COLUMN IF NOT EXISTS engaged_sessions UInt64 DEFAULT 0
    SQL

    execute <<~SQL
      ALTER TABLE link_session_daily
        ADD COLUMN IF NOT EXISTS engaged_duration_ms_sum UInt64 DEFAULT 0
    SQL
  end
end
