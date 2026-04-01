class AddPartialIndexesToPurchaseEventsAndLinks < ActiveRecord::Migration[8.0]
  def change
    # purchase_events: replace full boolean index with partial — the vast
    # majority of rows are processed=true so only the unprocessed slice
    # matters for the atomic‐claim query in ProcessPurchaseEventJob.
    remove_index :purchase_events, column: :processed, name: :index_purchase_events_on_processed
    add_index :purchase_events, :id,
              where: "processed = false",
              name: :index_purchase_events_on_unprocessed
  end
end
