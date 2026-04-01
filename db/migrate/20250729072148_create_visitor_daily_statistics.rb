class CreateVisitorDailyStatistics < ActiveRecord::Migration[7.0]
  def change
   create_table :visitor_daily_statistics do |t|
      t.references :visitor, null: false, foreign_key: true
      t.date :event_date, null: false

      t.integer :views, default: 0, null: false
      t.integer :opens, default: 0, null: false
      t.integer :installs, default: 0, null: false
      t.integer :reinstalls, default: 0, null: false
      t.integer :time_spent, default: 0, null: false
      t.bigint :revenue, default: 0, null: false # revenue in cents

      t.timestamps
    end

    add_index :visitor_daily_statistics, [:visitor_id, :event_date], unique: true
  end
end
