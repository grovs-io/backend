class CreateScreenAliases < ActiveRecord::Migration[8.1]
  def change
    create_table :screen_aliases do |t|
      t.references :project, null: false, foreign_key: true
      t.string :screen_identifier, null: false
      t.string :alias_name, null: false
      t.timestamps
    end

    add_index :screen_aliases, [:project_id, :screen_identifier], unique: true
  end
end
