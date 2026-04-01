class AddApiKeyToInstance < ActiveRecord::Migration[6.1]
  def change
    add_column :instances, :api_key, :string, null: false
  end
end
