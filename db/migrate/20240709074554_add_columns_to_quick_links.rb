class AddColumnsToQuickLinks < ActiveRecord::Migration[6.1]
  def change
    add_column :quick_links, :desktop, :string
    add_column :quick_links, :desktop_linux, :string
  end
end
