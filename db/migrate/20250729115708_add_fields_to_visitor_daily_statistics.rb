class AddFieldsToVisitorDailyStatistics < ActiveRecord::Migration[7.0]
  def change
    add_column :visitor_daily_statistics, :reactivations, :integer, default: 0, null: false
    add_column :visitor_daily_statistics, :app_opens, :integer, default: 0, null: false
    add_column :visitor_daily_statistics, :user_referred, :integer, default: 0, null: false
  end
end
