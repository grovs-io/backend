class CreateDailyProjectMetrics < ActiveRecord::Migration[7.0]
  def change
    create_table :daily_project_metrics do |t|
      t.integer :project_id, null: false
      t.date :event_date, null: false

      t.integer :views, default: 0, null: false
      t.integer :installs, default: 0, null: false
      t.integer :opens, default: 0, null: false
      t.integer :reinstalls, default: 0, null: false
      t.integer :link_views, default: 0, null: false
      t.integer :returning_users, default: 0, null: false
      t.integer :referred_users, default: 0, null: false
      t.integer :organic_users, default: 0, null: false
      t.integer :new_users, default: 0, null: false

      t.timestamps
    end

    add_index :daily_project_metrics, [:project_id, :event_date], unique: true
    add_index :daily_project_metrics, :event_date
  end
end
