# frozen_string_literal: true

# Collapse ClickHouse to ONE events table. The plain `events` table is no longer
# written or read: explorer/sessions read the deduped store, the breakdown rollups
# rebuild from it, and all its materialized views were dropped in the previous
# migration. Drop it and rename the deduped canonical store to `events`, so there
# is a single events table (a ReplacingMergeTree deduped by event_id).
#
# Data-safe: the canonical store was dual-written alongside plain events and holds
# the same events (deduped), and plain events was never the source of truth (PG is).
# Forward-only, idempotent.
class CollapseToSingleEventsTable < Clickhouse::Migration
  def up
    # Idempotent + safe. Collapse ONLY while the canonical store still exists. If it
    # is already gone — a retry after a crash between RENAME and recording, or an
    # already-collapsed environment — do nothing. This is critical: after collapse,
    # `events` IS the renamed canonical store, so a blind `DROP events` on re-run
    # would destroy the real data. ClickHouse has no conditional DDL, so guard in Ruby.
    return unless table_exists?('events_canonical')

    execute "DROP TABLE IF EXISTS events"
    execute "RENAME TABLE events_canonical TO events"
  end

  private

  def table_exists?(name)
    @connection.select_value(
      "SELECT count() FROM system.tables WHERE database = currentDatabase() AND name = '#{name}'"
    ).to_i.positive?
  end
end
