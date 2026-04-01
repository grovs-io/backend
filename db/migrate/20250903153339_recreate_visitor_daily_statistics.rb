class RecreateVisitorDailyStatistics < ActiveRecord::Migration[7.0]
  def up
    drop_table :visitor_daily_statistics, if_exists: true

    create_table :visitor_daily_statistics, id: :bigserial, primary_key: :id do |t|
      t.bigint :visitor_id,  null: false
      t.bigint :project_id
      t.bigint :invited_by_id

      t.date   :event_date,  null: false
      t.string :platform,    null: false, default: "web"

      t.integer :views,         null: false, default: 0
      t.integer :opens,         null: false, default: 0
      t.integer :installs,      null: false, default: 0
      t.integer :reinstalls,    null: false, default: 0
      t.integer :time_spent,    null: false, default: 0
      t.integer :revenue,       null: false, default: 0
      t.integer :reactivations, null: false, default: 0
      t.integer :app_opens,     null: false, default: 0
      t.integer :user_referred, null: false, default: 0

      t.timestamps
    end

    # FK to visitors with the requested name
    add_foreign_key :visitor_daily_statistics, :visitors,
                    column: :visitor_id,
                    name:   "fk_rails_21a96a0bbe"

    # Indexes requested (no 'event' column)
    add_index :visitor_daily_statistics, [:event_date, :project_id],
              name: "idx_vds_date_project"
    add_index :visitor_daily_statistics, [:event_date, :project_id, :platform],
              name: "idx_vds_date_project_platform"

    # (Optional but helpful) join speed-up
    add_index :visitor_daily_statistics, :visitor_id, name: "idx_vds_visitor_id"
  end

  def down
    drop_table :visitor_daily_statistics, if_exists: true
  end
end
