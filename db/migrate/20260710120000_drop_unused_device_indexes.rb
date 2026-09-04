# frozen_string_literal: true

# Drops indexes with zero lifetime scans (pg_stat_user_indexes, stats never reset).
# index_devices_on_updated_at alone was 66 GB of bloat from per-visit device saves.
# if_exists/if_not_exists: prod indexes were already dropped manually.
class DropUnusedDeviceIndexes < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    remove_index :devices, name: :index_devices_on_updated_at, algorithm: :concurrently, if_exists: true
    remove_index :devices, name: :index_devices_on_ip,         algorithm: :concurrently, if_exists: true
    remove_index :devices, name: :index_devices_on_remote_ip,  algorithm: :concurrently, if_exists: true
  end

  def down
    add_index :devices, :updated_at, algorithm: :concurrently, if_not_exists: true
    add_index :devices, :ip,         algorithm: :concurrently, if_not_exists: true
    add_index :devices, :remote_ip,  algorithm: :concurrently, if_not_exists: true
  end
end
