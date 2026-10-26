class CreateSegments < ActiveRecord::Migration[8.1]
  def change
    create_table :segments do |t|
      t.references :project, null: false, foreign_key: true, index: false
      t.string :name, null: false
      t.text :description
      t.jsonb :definition, null: false, default: {}
      t.string :definition_hash, null: false
      t.boolean :archived, null: false, default: false
      t.references :created_by, foreign_key: { to_table: :users, on_delete: :nullify }
      t.string :identifier_list_generation
      t.timestamps
    end
    add_index :segments, %i[project_id archived]
  end
end
