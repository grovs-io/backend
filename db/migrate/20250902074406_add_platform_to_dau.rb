class AddPlatformToDau < ActiveRecord::Migration[7.0]
  def change
    add_column :project_daily_active_users, :platform, :string, null: false, default: "web"

    add_index :project_daily_active_users,
              [:project_id, :event_date, :platform],
              unique: true,
              name: "idx_project_dau_on_project_date_platform"
  end
end
