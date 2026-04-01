class ChangePurchaseEventsPriceColumnsToBigint < ActiveRecord::Migration[7.0]
  def up
    change_column :purchase_events, :price_cents, :bigint
    change_column :purchase_events, :usd_price_cents, :bigint
  end

  def down
    change_column :purchase_events, :price_cents, :integer
    change_column :purchase_events, :usd_price_cents, :integer
  end
end
