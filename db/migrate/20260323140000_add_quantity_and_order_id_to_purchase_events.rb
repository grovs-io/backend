class AddQuantityAndOrderIdToPurchaseEvents < ActiveRecord::Migration[7.1]
  def change
    add_column :purchase_events, :quantity, :integer, default: 1, null: false
    add_column :purchase_events, :order_id, :string
    add_index :purchase_events, [:order_id, :project_id], name: "idx_purchase_events_order_project"
  end
end
