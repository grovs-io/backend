class CreateDeviceLastSeens < ActiveRecord::Migration[8.1]
  def change
    # No FKs: orphan project_ids exist in CH events and would wedge the bulk backfill upsert.
    create_table :device_last_seens do |t|
      t.bigint :project_id, null: false
      t.bigint :device_id, null: false
      t.datetime :last_seen_at, null: false
      t.timestamps
    end
    add_index :device_last_seens, %i[project_id device_id], unique: true, name: "uniq_dls_on_project_and_device"
    # Update-heavy (one touch per active device per batch): keep HOT updates viable, vacuum eagerly.
    reversible do |dir|
      dir.up { execute "ALTER TABLE device_last_seens SET (fillfactor = 80, autovacuum_vacuum_scale_factor = 0.02)" }
    end
  end
end
