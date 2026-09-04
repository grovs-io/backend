# frozen_string_literal: true

# Re-add the equality/IN filter skip indexes that existed on the old plain `events`
# table but were never carried onto the deduped canonical store before it was renamed
# to `events` (collapse_to_single_events_table). These accelerate the explorer's
# equality filters (country/event_type/event_name/screen_name) and compose fine with
# FINAL. Idempotent (IF NOT EXISTS) + MATERIALIZE so existing parts get the index too.
#
# The p_recent_events PROJECTION is intentionally NOT restored: normal projections are
# not used under FINAL (every exact read of this ReplacingMergeTree uses FINAL), and it
# was a SELECT * projection that would double storage for no query benefit here.
class ReaddEventsSkipIndexes < Clickhouse::Migration
  INDEXES = {
    'idx_country'     => 'country TYPE set(200) GRANULARITY 4',
    'idx_event_type'  => 'event_type TYPE set(20) GRANULARITY 4',
    'idx_event_name'  => 'event_name TYPE bloom_filter(0.01) GRANULARITY 4',
    'idx_screen_name' => 'screen_name TYPE bloom_filter(0.01) GRANULARITY 4'
  }.freeze

  def up
    INDEXES.each do |name, definition|
      execute "ALTER TABLE events ADD INDEX IF NOT EXISTS #{name} #{definition}"
      execute "ALTER TABLE events MATERIALIZE INDEX IF EXISTS #{name}"
    end
  end
end
