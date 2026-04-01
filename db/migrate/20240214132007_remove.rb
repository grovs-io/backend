class Remove < ActiveRecord::Migration[6.1]
  def change
    drop_table :projects_users
  end
end
