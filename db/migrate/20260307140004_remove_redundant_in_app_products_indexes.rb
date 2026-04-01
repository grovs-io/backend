class RemoveRedundantInAppProductsIndexes < ActiveRecord::Migration[7.0]
  disable_ddl_transaction!

  def change
    # The unique index (project_id, platform, product_id) covers all these query patterns.
    remove_index :in_app_products, name: "index_in_app_products_on_platform_and_product_id",
                 algorithm: :concurrently, if_exists: true
    remove_index :in_app_products, name: "index_in_app_products_on_platform",
                 algorithm: :concurrently, if_exists: true
    remove_index :in_app_products, name: "index_in_app_products_on_product_id",
                 algorithm: :concurrently, if_exists: true
    remove_index :in_app_products, name: "index_in_app_products_on_project_id_and_platform",
                 algorithm: :concurrently, if_exists: true
    remove_index :in_app_products, name: "index_in_app_products_on_project_id",
                 algorithm: :concurrently, if_exists: true
  end
end
