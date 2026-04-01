class CreateStoreImages < ActiveRecord::Migration[7.0]
  def change
    create_table :store_images do |t|
      t.string :identifier, null: false
      t.string :platform, null: false
      t.timestamps
    end

    add_index :store_images, [:identifier, :platform], unique: true
  end
end
