class AddPushTokenToDevice < ActiveRecord::Migration[7.0]
  def change
    add_column :devices, :push_token, :string
  end
end
