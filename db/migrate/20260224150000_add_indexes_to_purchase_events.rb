class AddIndexesToPurchaseEvents < ActiveRecord::Migration[7.0]
  disable_ddl_transaction!

  def up
    # Remove duplicates in batches before adding unique index — keep the newest record per group
    loop do
      deleted = execute(<<~SQL).cmd_tuples
        DELETE FROM purchase_events
        WHERE id IN (
          SELECT id FROM purchase_events
          WHERE transaction_id IS NOT NULL
            AND id NOT IN (
              SELECT MAX(id)
              FROM purchase_events
              WHERE transaction_id IS NOT NULL
              GROUP BY project_id, transaction_id, event_type
            )
          LIMIT 10000
        )
      SQL
      break if deleted == 0
    end

    add_index :purchase_events, [:project_id, :transaction_id, :event_type],
              unique: true,
              name: 'idx_purchase_events_unique_txn',
              algorithm: :concurrently
    add_index :purchase_events, :transaction_id,
              name: 'index_purchase_events_on_transaction_id',
              algorithm: :concurrently
    add_index :purchase_events, :original_transaction_id,
              name: 'index_purchase_events_on_original_transaction_id',
              algorithm: :concurrently
    add_index :purchase_events, [:project_id, :date, :event_type],
              name: 'index_purchase_events_on_project_date_event',
              algorithm: :concurrently
  end

  def down
    remove_index :purchase_events, name: 'idx_purchase_events_unique_txn', algorithm: :concurrently
    remove_index :purchase_events, name: 'index_purchase_events_on_transaction_id', algorithm: :concurrently
    remove_index :purchase_events, name: 'index_purchase_events_on_original_transaction_id', algorithm: :concurrently
    remove_index :purchase_events, name: 'index_purchase_events_on_project_date_event', algorithm: :concurrently
  end
end
