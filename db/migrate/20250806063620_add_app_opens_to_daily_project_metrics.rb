class AddAppOpensToDailyProjectMetrics < ActiveRecord::Migration[7.0]
  def change
    add_column :daily_project_metrics, :app_opens, :integer
  end
end
