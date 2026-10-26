class CreateSegmentSizeSnapshots < ActiveRecord::Migration[8.1]
  def change
    create_table :segment_size_snapshots do |t|
      t.references :segment, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.date :date, null: false
      t.string :definition_hash, null: false
      t.bigint :persons, null: false, default: 0
      t.bigint :devices, null: false, default: 0
      t.boolean :incomplete, null: false, default: false
      t.timestamps
    end
    add_index :segment_size_snapshots, %i[segment_id date], unique: true
  end
end
