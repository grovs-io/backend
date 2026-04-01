class AddProductIdToPurchaseEvent < ActiveRecord::Migration[7.0]
  def change
    add_column :purchase_events, :product_id, :string
  end
end
