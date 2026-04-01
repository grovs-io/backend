class AddPrimaryKeyToVisitorDailyStatistics < ActiveRecord::Migration[7.0]
  def up
    drop_table :visitor_daily_statistics, if_exists: true

    create_table :visitor_daily_statistics, id: :bigserial, primary_key: :id do |t|
      t.bigint :visitor_id, null: false
      t.date   :event_date, null: false

      t.integer :views,        default: 0, null: false
      t.integer :opens,        default: 0, null: false
      t.integer :installs,     default: 0, null: false
      t.integer :reinstalls,   default: 0, null: false
      t.integer :time_spent,   default: 0, null: false
      t.integer :revenue,      default: 0, null: false
      t.integer :reactivations,default: 0, null: false
      t.integer :app_opens,    default: 0, null: false
      t.integer :user_referred,default: 0, null: false

      t.bigint :project_id
      t.bigint :invited_by_id

      t.index [:visitor_id, :event_date], unique: true, name: "idx_vds_visitor_date"
    end

    # Add the foreign key to visitors table
    add_foreign_key :visitor_daily_statistics, :visitors,
                    column: :visitor_id,
                    name: "fk_rails_21a96a0bbe"
  end

  def down
    drop_table :visitor_daily_statistics, if_exists: true
  end
end
