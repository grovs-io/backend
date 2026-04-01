class AddCompositeIndexToPurchaseEvents < ActiveRecord::Migration[7.0]
  disable_ddl_transaction!

  def change
    add_index :purchase_events,
              [:device_id, :project_id, :product_id, :event_type],
              algorithm: :concurrently,
              name: "idx_purchase_events_device_project_product_event"
  end
end
