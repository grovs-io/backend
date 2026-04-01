class DropPurchasedProducts < ActiveRecord::Migration[7.0]
  def up
    drop_table :purchased_products if table_exists?(:purchased_products)
  end

  def down
    create_table :purchased_products, id: false do |t|
      t.bigint :visitor_id, null: false
      t.bigint :in_app_product_id, null: false
      t.bigint :project_id, null: false

      t.index [:visitor_id, :in_app_product_id, :project_id],
              name: "idx_unique_visitor_inapp_product_per_project", unique: true
      t.index [:visitor_id, :project_id], name: "idx_visitor_project"
      t.index :visitor_id
      t.index :in_app_product_id
      t.index :project_id
    end

    add_foreign_key :purchased_products, :visitors, on_delete: :cascade
    add_foreign_key :purchased_products, :in_app_products, on_delete: :cascade
    add_foreign_key :purchased_products, :projects, on_delete: :cascade
  end
end
