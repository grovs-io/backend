class AddRevenueColumnsToDailyProjectMetrics < ActiveRecord::Migration[7.0]
  def change
    add_column :daily_project_metrics, :revenue, :bigint, default: 0 unless column_exists?(:daily_project_metrics, :revenue)
    add_column :daily_project_metrics, :units_sold, :integer, default: 0 unless column_exists?(:daily_project_metrics, :units_sold)
    add_column :daily_project_metrics, :cancellations, :integer, default: 0 unless column_exists?(:daily_project_metrics, :cancellations)
    add_column :daily_project_metrics, :first_time_purchases, :integer, default: 0 unless column_exists?(:daily_project_metrics, :first_time_purchases)
  end
end
