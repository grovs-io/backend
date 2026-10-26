class CreateSegmentExports < ActiveRecord::Migration[8.1]
  def change
    create_table :segment_exports do |t|
      t.references :project, null: false, foreign_key: true, index: false
      t.references :segment, null: false, foreign_key: true
      t.references :user, foreign_key: { on_delete: :nullify }
      t.string :status, null: false, default: "pending"
      t.integer :rows
      t.jsonb :definition, null: false, default: {}
      t.string :definition_hash, null: false
      t.string :identifier_list_generation
      t.string :error
      t.timestamps
    end
    add_index :segment_exports, %i[project_id created_at]
  end
end
