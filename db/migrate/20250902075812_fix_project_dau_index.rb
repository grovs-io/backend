class FixProjectDauIndex < ActiveRecord::Migration[7.0]
  def change
    remove_index :project_daily_active_users, name: "index_project_daily_active_users_on_project_id_and_event_date"
  end
end
