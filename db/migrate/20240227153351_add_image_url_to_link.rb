class AddImageUrlToLink < ActiveRecord::Migration[6.1]
  def change
    add_column :links, :image_url, :string
  end
end
