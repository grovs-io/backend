class CreatePurchaseEvents < ActiveRecord::Migration[7.0]
  def change
    create_table :purchase_events do |t|
      t.string :event_type
      t.references :device, null: true, foreign_key: true
      t.references :project, null: true, foreign_key: true
      t.string :bundle_id
      t.integer :price_cents
      t.string :currency
      t.integer :usd_price_cents
      t.datetime :date

      t.timestamps
    end

    add_index :purchase_events, :event_type
    add_index :purchase_events, :bundle_id
    add_index :purchase_events, :date
  end
end
