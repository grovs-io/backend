class AddAppIdIndexToRpushNotifications < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_index :rpush_notifications, :app_id, algorithm: :concurrently, if_not_exists: true
  end
end
