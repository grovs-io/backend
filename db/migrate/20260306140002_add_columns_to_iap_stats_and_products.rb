class AddColumnsToIapStatsAndProducts < ActiveRecord::Migration[7.0]
  def up
    if table_exists?(:in_app_product_daily_statistics)
      add_column :in_app_product_daily_statistics, :repeat_purchases, :integer, default: 0, null: false unless column_exists?(:in_app_product_daily_statistics, :repeat_purchases)
      add_column :in_app_product_daily_statistics, :device_revenue, :bigint, default: 0, null: false unless column_exists?(:in_app_product_daily_statistics, :device_revenue)
    end

    if table_exists?(:in_app_products)
      add_column :in_app_products, :unique_purchasing_devices, :integer, default: 0, null: false unless column_exists?(:in_app_products, :unique_purchasing_devices)
    end
  end

  def down
    remove_column :in_app_product_daily_statistics, :repeat_purchases if table_exists?(:in_app_product_daily_statistics) && column_exists?(:in_app_product_daily_statistics, :repeat_purchases)
    remove_column :in_app_product_daily_statistics, :device_revenue if table_exists?(:in_app_product_daily_statistics) && column_exists?(:in_app_product_daily_statistics, :device_revenue)
    remove_column :in_app_products, :unique_purchasing_devices if table_exists?(:in_app_products) && column_exists?(:in_app_products, :unique_purchasing_devices)
  end
end
