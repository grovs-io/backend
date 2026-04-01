class AddLinkIdToPurchaseEvents < ActiveRecord::Migration[7.0]
  def change
    add_reference :purchase_events, :link, foreign_key: true, null: true
  end
end
