class AddStoreFlagToPurchaseEvent < ActiveRecord::Migration[7.0]
  def change
    add_column :purchase_events, :webhook_validated, :boolean, default: false
    add_column :purchase_events, :store, :boolean, default: false
  end
end
