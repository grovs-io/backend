class IndexDeviceLastSeensByProjectAndLastSeen < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  # SDK status reads a project's devices seen in the last 30 days.
  def change
    add_index :device_last_seens, [:project_id, :last_seen_at], algorithm: :concurrently, if_not_exists: true
  end
end
