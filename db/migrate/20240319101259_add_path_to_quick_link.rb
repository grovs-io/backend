class AddPathToQuickLink < ActiveRecord::Migration[6.1]
  def change
    add_column :quick_links, :path, :string, null: false
  end
end
