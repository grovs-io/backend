class ChangeLinkDailyStatisticsTimeSpentToBigint < ActiveRecord::Migration[7.0]
  def up
    change_column :link_daily_statistics, :time_spent, :bigint, default: 0, null: false
  end

  def down
    change_column :link_daily_statistics, :time_spent, :integer, default: 0, null: false
  end
end
