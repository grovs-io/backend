class AddExperimentsToInApp < ActiveRecord::Migration[8.1]
  def change
    change_table :in_app_campaigns, bulk: true do |t|
      t.integer :control_group
      t.jsonb :conversion
      t.jsonb :variants
    end
    add_column :in_app_settings, :control_group, :integer, null: false, default: 0
  end
end
