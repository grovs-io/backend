class CreateInstanceRoles < ActiveRecord::Migration[6.1]
  def change
    create_table :instance_roles do |t|
      t.belongs_to :instance
      t.belongs_to :user
      t.string :role, null: false

      t.timestamps
    end
  end
end
