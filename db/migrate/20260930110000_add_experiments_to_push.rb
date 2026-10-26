class AddExperimentsToPush < ActiveRecord::Migration[8.1]
  def change
    change_table :push_campaigns, bulk: true do |t|
      t.integer :control_group
      t.jsonb :conversion
      t.jsonb :variants
      t.integer :test_share
      t.integer :held, null: false, default: 0
      t.integer :waiting, null: false, default: 0
    end
    add_column :push_deliveries, :variant, :string, limit: 1
  end
end
