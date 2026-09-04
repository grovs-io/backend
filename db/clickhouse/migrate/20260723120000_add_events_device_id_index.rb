# frozen_string_literal: true

# bloom_filter, not minmax: device_ids scatter within a granule under this ORDER BY.
class AddEventsDeviceIdIndex < Clickhouse::Migration
  def up
    execute "ALTER TABLE events ADD INDEX IF NOT EXISTS idx_device device_id TYPE bloom_filter(0.01) GRANULARITY 4"
  end
end
