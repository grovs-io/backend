class AddProcessedToPurchaseEvents < ActiveRecord::Migration[7.0]
  def up
    return if column_exists?(:purchase_events, :processed)

    add_column :purchase_events, :processed, :boolean, default: false, null: false
    add_index :purchase_events, :processed, name: "index_purchase_events_on_processed"
  end

  def down
    remove_index :purchase_events, name: "index_purchase_events_on_processed", if_exists: true
    remove_column :purchase_events, :processed, if_exists: true
  end
end
