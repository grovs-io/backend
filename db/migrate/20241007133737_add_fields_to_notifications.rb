class AddFieldsToNotifications < ActiveRecord::Migration[7.0]
  def change
    add_column :notifications, :auto_display, :boolean, default: false
    add_column :notifications, :send_push, :boolean, default: false
  end
end
