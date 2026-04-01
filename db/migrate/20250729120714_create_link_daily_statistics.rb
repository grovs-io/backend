class CreateLinkDailyStatistics < ActiveRecord::Migration[7.0]
  def change
    create_table :link_daily_statistics do |t|
      t.references :link, null: false, foreign_key: true
      t.date :event_date, null: false

      t.integer :views, default: 0, null: false
      t.integer :opens, default: 0, null: false
      t.integer :installs, default: 0, null: false
      t.integer :reinstalls, default: 0, null: false
      t.integer :time_spent, default: 0, null: false
      t.integer :reactivations, default: 0, null: false
      t.integer :app_opens, default: 0, null: false
      t.integer :user_referred, default: 0, null: false
      t.bigint  :revenue, default: 0, null: false # in cents

      t.timestamps
    end

    add_index :link_daily_statistics, [:link_id, :event_date], unique: true
  end
end
