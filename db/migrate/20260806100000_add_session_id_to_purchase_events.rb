class AddSessionIdToPurchaseEvents < ActiveRecord::Migration[8.1]
  def change
    add_column :purchase_events, :session_id, :string, default: "", null: false
  end
end
