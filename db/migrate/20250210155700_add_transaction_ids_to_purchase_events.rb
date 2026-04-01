class AddTransactionIdsToPurchaseEvents < ActiveRecord::Migration[7.0]
  def change
    add_column :purchase_events, :transaction_id, :string
    add_column :purchase_events, :original_transaction_id, :string
  end
end
