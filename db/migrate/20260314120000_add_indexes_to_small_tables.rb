class AddIndexesToSmallTables < ActiveRecord::Migration[7.0]
  disable_ddl_transaction!

  def change
    add_index :subscription_states, :device_id, algorithm: :concurrently, if_not_exists: true
    add_index :subscription_states, :link_id, algorithm: :concurrently, if_not_exists: true
    add_index :iap_webhook_messages, :instance_id, algorithm: :concurrently, if_not_exists: true
  end
end
