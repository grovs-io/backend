class CreateProjects < ActiveRecord::Migration[6.1]
  def change
    create_table :projects do |t|
      t.string :name, null: false
      t.string :identifier, null: false

      t.timestamps
    end

    add_index :projects, :identifier, unique: true
  end
end
