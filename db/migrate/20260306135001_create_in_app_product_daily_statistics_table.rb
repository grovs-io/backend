class CreateInAppProductDailyStatisticsTable < ActiveRecord::Migration[7.0]
  def up
    return if table_exists?(:in_app_product_daily_statistics)

    create_table :in_app_product_daily_statistics do |t|
      t.bigint :in_app_product_id, null: false
      t.bigint :project_id, null: false
      t.date :event_date, null: false
      t.bigint :revenue, default: 0, null: false
      t.integer :purchase_events, default: 0, null: false
      t.integer :canceled_events, default: 0, null: false
      t.integer :first_time_purchases
      t.string :platform, default: "web", null: false
      t.integer :repeat_purchases, default: 0, null: false
      t.bigint :device_revenue, default: 0, null: false

      t.timestamps
    end

    add_index :in_app_product_daily_statistics, [:event_date],
              name: "idx_iapds_event_date"
    add_index :in_app_product_daily_statistics, [:in_app_product_id, :event_date, :platform],
              unique: true, name: "idx_iapds_unique_product_event_date_platform"
    add_index :in_app_product_daily_statistics, [:project_id, :event_date],
              name: "idx_iapds_project_event_date"
  end

  def down
    drop_table :in_app_product_daily_statistics, if_exists: true
  end
end
