class CreateInAppProductsTable < ActiveRecord::Migration[7.0]
  def up
    return if table_exists?(:in_app_products)

    create_table :in_app_products do |t|
      t.bigint :project_id, null: false
      t.string :product_id, null: false
      t.string :platform, null: false
      t.integer :unique_purchasing_devices, default: 0, null: false

      t.timestamps
    end

    add_index :in_app_products, [:project_id, :platform, :product_id],
              unique: true, name: "idx_in_app_products_on_project_platform_product"
    add_index :in_app_products, [:project_id, :product_id],
              name: "index_in_app_products_on_project_id_and_product_id"
  end

  def down
    drop_table :in_app_products, if_exists: true
  end
end
