class AddPurchaseTypeToPurchaseEvents < ActiveRecord::Migration[7.0]
  def change
    add_column :purchase_events, :purchase_type, :string
  end
end
