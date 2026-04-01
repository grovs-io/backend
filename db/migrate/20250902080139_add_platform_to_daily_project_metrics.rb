class AddPlatformToDailyProjectMetrics < ActiveRecord::Migration[7.0]
  def change
    add_column :daily_project_metrics, :platform, :string, null: false, default: "web"

    # Drop the old 2-col unique index if it exists
    if index_exists?(:daily_project_metrics, [:project_id, :event_date], unique: true)
      remove_index :daily_project_metrics, column: [:project_id, :event_date]
    end

    add_index :daily_project_metrics,
              [:project_id, :event_date, :platform],
              unique: true,
              name: "idx_dpm_on_project_date_platform"
  end
end
