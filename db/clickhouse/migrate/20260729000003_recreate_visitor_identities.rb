# frozen_string_literal: true

# 002 was edited in place after being hand-applied somewhere; IF NOT EXISTS never re-applies there.
class RecreateVisitorIdentities < Clickhouse::Migration
  DDL = <<~SQL
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

  def up
    execute "DROP TABLE IF EXISTS visitor_identities" if superseded_engine?
    execute DDL
  end

  private

  # Only drops a table left by 002's original body, so replaying is a no-op not a wiped snapshot.
  def superseded_engine?
    Clickhouse.with do |conn|
      conn.select_value(
        "SELECT count() FROM system.tables WHERE database = currentDatabase() " \
        "AND name = 'visitor_identities' AND engine != 'MergeTree'"
      )
    end.to_i.positive?
  end
end
