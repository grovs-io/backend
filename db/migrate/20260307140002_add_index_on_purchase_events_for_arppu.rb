class AddIndexOnPurchaseEventsForArppu < ActiveRecord::Migration[7.0]
  disable_ddl_transaction!

  def change
    add_index :purchase_events,
              [:project_id, :product_id, :event_type, :device_id],
              name: "idx_purchase_events_arppu",
              algorithm: :concurrently,
              if_not_exists: true
  end
end
