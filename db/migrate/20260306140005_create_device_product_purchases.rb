class CreateDeviceProductPurchases < ActiveRecord::Migration[7.0]
  def change
    create_table :device_product_purchases do |t|
      t.bigint :device_id, null: false
      t.bigint :project_id, null: false
      t.string :product_id, null: false
      t.datetime :created_at, null: false
    end

    add_index :device_product_purchases,
              [:device_id, :project_id, :product_id],
              unique: true,
              name: "idx_device_product_purchases_unique"
  end
end
