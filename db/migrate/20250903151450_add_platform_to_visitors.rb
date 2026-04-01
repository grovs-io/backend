class AddPlatformToVisitors < ActiveRecord::Migration[7.0]
  def change
     add_column :visitor_daily_statistics, :platform, :string, null: false, default: "web"

    # Drop the old 2-col unique index if it exists
    if index_exists?(:visitor_daily_statistics, [:project_id, :event_date], unique: true)
      remove_index :visitor_daily_statistics, column: [:project_id, :event_date]
    end

    add_index :visitor_daily_statistics,
              [:project_id, :event_date, :platform],
              unique: true,
              name: "idx_dpm_on_project_date_visitors"
  end
end
