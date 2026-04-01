class AddExpiresDateToPurchaseEvents < ActiveRecord::Migration[7.0]
  def change
    add_column :purchase_events, :expires_date, :datetime, null: true
  end
end
