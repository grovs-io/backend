class CreateIosServerApiKeys < ActiveRecord::Migration[7.0]
  def change
    create_table :ios_server_api_keys do |t|
      t.references :ios_configuration, null: false, foreign_key: true
      t.text :private_key, null: false
      t.string :key_id, null: false
      t.string :issuer_id, null: false
      t.string :filename
      t.timestamps
    end
  end
end
