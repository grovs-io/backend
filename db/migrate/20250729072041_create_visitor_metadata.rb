class CreateVisitorMetadata < ActiveRecord::Migration[7.0]
  def change
    create_table :visitor_metadata do |t|
      t.references :visitor, null: false, foreign_key: true, index: { unique: true }
      t.bigint :invited_by_id
      t.string :invited_by_name
      t.string :platform

      t.timestamps
    end
  end
end
