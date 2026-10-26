class AddSettledIndexToRpushNotifications < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_index :rpush_notifications, :created_at, where: "delivered OR failed", name: "index_rpush_notifications_settled_created_at",
              algorithm: :concurrently, if_not_exists: true
  end
end
