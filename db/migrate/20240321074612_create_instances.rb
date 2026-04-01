class CreateInstances < ActiveRecord::Migration[6.1]
  def change
    create_table :instances do |t|

      t.references :production, foreign_key: { to_table: :projects }
      t.references :test, foreign_key: { to_table: :projects }

      t.timestamps
    end
  end
end
