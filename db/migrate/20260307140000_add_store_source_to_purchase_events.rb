class AddStoreSourceToPurchaseEvents < ActiveRecord::Migration[7.0]
  def change
    add_column :purchase_events, :store_source, :string, default: nil
  end
end
