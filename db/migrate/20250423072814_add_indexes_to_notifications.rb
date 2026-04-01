class AddIndexesToNotifications < ActiveRecord::Migration[7.0]
  def change
    # Index for notification messages
    unless index_exists?(:notification_messages, :read)
      add_index :notification_messages, :read
    end

    # Composite index for auto-display notifications
    unless index_exists?(:notification_messages, [:notification_id, :read])
      add_index :notification_messages, [:notification_id, :read], 
                name: 'idx_notification_messages_on_notification_and_read'
    end

    # Index for notifications auto_display flag
    unless index_exists?(:notifications, :auto_display)
      add_index :notifications, :auto_display
    end
  end
end