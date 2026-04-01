class CreateProjectDailyActiveUsers < ActiveRecord::Migration[7.0]
  def change
    create_table :project_daily_active_users do |t|
      t.bigint :project_id
      t.date :event_date
      t.integer :active_users, null: false, default: 0

      t.timestamps
    end

    add_index :project_daily_active_users, [:project_id, :event_date], unique: true
  end
end
