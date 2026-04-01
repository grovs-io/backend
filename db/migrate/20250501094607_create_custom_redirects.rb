class CreateCustomRedirects < ActiveRecord::Migration[7.0]
  def change
    create_table :custom_redirects do |t|
      t.references :link, null: false, foreign_key: true
      t.string :platform, null: false # "IOS", "ANDROID", "DESKTOP"
      t.string :url
      t.boolean :open_app_if_installed, default: true, null: false

      t.timestamps
    end

    add_index :custom_redirects, [:link_id, :platform], unique: true
  end
end
