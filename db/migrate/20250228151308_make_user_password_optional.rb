class MakeUserPasswordOptional < ActiveRecord::Migration[7.0]
  def change
    change_column_null :users, :encrypted_password, true
  end
end
