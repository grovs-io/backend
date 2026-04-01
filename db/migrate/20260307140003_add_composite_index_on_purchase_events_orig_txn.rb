class AddCompositeIndexOnPurchaseEventsOrigTxn < ActiveRecord::Migration[7.0]
  disable_ddl_transaction!

  def change
    add_index :purchase_events,
              [:project_id, :original_transaction_id, :event_type],
              name: "idx_purchase_events_project_orig_txn_type",
              algorithm: :concurrently,
              if_not_exists: true

    remove_index :purchase_events,
                 column: :original_transaction_id,
                 name: "index_purchase_events_on_original_transaction_id",
                 algorithm: :concurrently,
                 if_exists: true
  end
end
