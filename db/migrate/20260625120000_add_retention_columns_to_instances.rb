class AddRetentionColumnsToInstances < ActiveRecord::Migration[8.1]
  def change
    change_table :instances, bulk: true do |t|
      t.integer :cold_storage_days, null: false, default: 365
      t.integer :delete_days, null: false, default: 730
    end
  end
end
