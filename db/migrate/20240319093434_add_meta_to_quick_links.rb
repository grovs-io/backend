class AddMetaToQuickLinks < ActiveRecord::Migration[6.1]
  def change
    add_column :quick_links, :title, :string
    add_column :quick_links, :subtitle, :string
    add_column :quick_links, :image_url, :string
  end
end
