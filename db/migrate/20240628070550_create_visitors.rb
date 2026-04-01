class CreateVisitors < ActiveRecord::Migration[6.1]
  def change
    create_table :visitors do |t|
      t.references :project, null: false, foreign_key: true
      t.string :sdk_identifier
      t.jsonb :sdk_attributes

      t.timestamps
    end
  end
end
