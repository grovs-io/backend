class AddPlatformToDailyStatistics < ActiveRecord::Migration[7.0]
  def change
     # 1. Add platform column (default 'unknown')
    add_column :visitor_daily_statistics, :platform, :string, null: false, default: "web"
    add_column :link_daily_statistics,    :platform, :string, null: false, default: "web"

    # 2. Drop old unique indexes and replace them with new ones that include platform

    # Visitor daily stats
    remove_index :visitor_daily_statistics, name: "index_visitor_daily_stats_on_project_visitor_date"
    execute "ALTER TABLE visitor_daily_statistics DROP CONSTRAINT IF EXISTS visitor_daily_statistics_pkey"
    add_index :visitor_daily_statistics,
      [:project_id, :visitor_id, :event_date, :platform],
      unique: true,
      name: "visitor_daily_statistics_pkey" # Rails can create the PK-style unique index

    # Link daily stats
    remove_index :link_daily_statistics, name: "index_link_daily_stats_on_project_link_date"
    execute "ALTER TABLE link_daily_statistics DROP CONSTRAINT IF EXISTS link_daily_statistics_pkey"
    add_index :link_daily_statistics,
      [:project_id, :link_id, :event_date, :platform],
      unique: true,
      name: "link_daily_statistics_pkey"

    # 3. Optional: supporting indexes for faster querying
    add_index :visitor_daily_statistics,
      [:event_date, :project_id, :platform],
      name: "index_vds_on_date_project_platform"

    add_index :link_daily_statistics,
      [:event_date, :project_id, :platform],
      name: "index_lds_on_date_project_platform"
  end
end
