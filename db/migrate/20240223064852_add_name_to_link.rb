class AddNameToLink < ActiveRecord::Migration[6.1]
  def change
    add_column :links, :name, :string, null: false
  end
end
