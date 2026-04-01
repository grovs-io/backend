class AddGenericImageUrlToDomain < ActiveRecord::Migration[6.1]
  def change
    add_column :domains, :generic_image_url, :string
  end
end
