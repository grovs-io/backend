class CreateInstalledApps < ActiveRecord::Migration[7.0]
  def change
    create_table :installed_apps do |t|
      t.references :device, null: false, foreign_key: true
      t.references :project, null: false, foreign_key: true

      t.timestamps
    end

    add_index :installed_apps, [:device_id, :project_id], unique: true
  end
end
