class CreateAndroidServerApiKeys < ActiveRecord::Migration[7.0]
  def change
    create_table :android_server_api_keys do |t|
      t.references :android_configuration, null: false, foreign_key: true
      t.timestamps
    end
  end
end
