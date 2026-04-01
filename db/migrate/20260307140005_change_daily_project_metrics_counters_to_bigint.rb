class ChangeDailyProjectMetricsCountersToBigint < ActiveRecord::Migration[7.0]
  def up
    return unless table_exists?(:daily_project_metrics)

    change_column :daily_project_metrics, :units_sold, :bigint, default: 0
    change_column :daily_project_metrics, :cancellations, :bigint, default: 0
    change_column :daily_project_metrics, :first_time_purchases, :bigint, default: 0
  end

  def down
    return unless table_exists?(:daily_project_metrics)

    change_column :daily_project_metrics, :units_sold, :integer, default: 0
    change_column :daily_project_metrics, :cancellations, :integer, default: 0
    change_column :daily_project_metrics, :first_time_purchases, :integer, default: 0
  end
end
