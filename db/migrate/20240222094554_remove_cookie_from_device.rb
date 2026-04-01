class RemoveCookieFromDevice < ActiveRecord::Migration[6.1]
  def change
    remove_column :devices, :cookie
  end
end
