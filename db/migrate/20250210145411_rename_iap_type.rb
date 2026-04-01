class RenameIapType < ActiveRecord::Migration[7.0]
  def change
    rename_column :iap_webhook_messages, :type, :notification_type
  end
end
